use crate::setup_install_state::{managed_tree_decision, read_state};
use crate::setup_support::{SetupResult, sha256_text, write_json_atomic};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[path = "setup_managed_tree_test_support.rs"]
mod test_support;
#[path = "setup_managed_tree_state.rs"]
mod tree_state;
use test_support::{
    inject_collision, inject_failure, inject_postverify, inject_public_replacement,
};
use tree_state::carry_tracked_files;

const USAGE: &str = "Usage: vibeguard-runtime setup-state-quarantine-managed-tree <state-file> <previous-state-file> <dest-dir> <source-prefix>";
const RELEASE_USAGE: &str = "Usage: vibeguard-runtime setup-state-release-quarantined-tree <state-file> <previous-state-file> <dest-dir> <source-prefix>";
const TRANSACTION_VERSION: u64 = 1;

#[derive(Clone, Debug, Eq, PartialEq)]
struct Transaction {
    version: u64,
    phase: String,
    dest: String,
    quarantine: String,
    transaction: String,
    source_prefix: String,
    tracked_digest: String,
    install_state_generation: u64,
    nonce: String,
}

pub fn run(args: &[String]) -> SetupResult<()> {
    if args.len() != 4 {
        return Err(USAGE.into());
    }
    let current_state = Path::new(&args[0]);
    let previous_state = Path::new(&args[1]);
    let states = [current_state, previous_state];
    let dest = absolute(Path::new(&args[2]));
    let parent = dest
        .parent()
        .ok_or("managed tree has no parent directory")?;
    let name = dest
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .ok_or("managed tree name must be non-empty UTF-8")?;
    if !parent.is_dir() {
        return Err(format!(
            "managed tree parent is not a directory: {}",
            parent.display()
        )
        .into());
    }

    if let Some(existing) =
        recover_or_find_committed(&states, current_state, &dest, parent, name, &args[3])?
    {
        println!("QUARANTINED\t{}", existing.display());
        return Ok(());
    }

    if matches!(
        fs::symlink_metadata(&dest),
        Err(error) if error.kind() == io::ErrorKind::NotFound
    ) {
        println!("ABSENT");
        return Ok(());
    }

    let tracked_digest = owned_digest(&states, &dest, &args[3], &dest)?.ok_or_else(|| {
        format!(
            "managed tree is not an exact VibeGuard-owned copy: {}",
            dest.display()
        )
    })?;
    let generation = current_generation(current_state)?;
    let mut transaction =
        reserve_transaction(&dest, parent, name, &args[3], &tracked_digest, generation)?;
    let transaction_path = PathBuf::from(&transaction.transaction);
    let quarantine = PathBuf::from(&transaction.quarantine);
    write_new_json_durable(&transaction_path, &transaction_value(&transaction))?;

    rename_noreplace(&dest, &quarantine).map_err(|error| {
        format!(
            "failed to atomically quarantine {}: {error}; intent retained at {}",
            dest.display(),
            transaction_path.display()
        )
    })?;
    sync_directory(parent)?;
    inject_failure(
        "VIBEGUARD_TEST_QUARANTINE_AFTER_RENAME",
        "injected failure after quarantine rename",
    )?;

    verify_exact(&states, &quarantine, &args[3], &dest)?;
    inject_postverify(&quarantine)?;
    inject_public_replacement(&dest)?;
    verify_exact(&states, &quarantine, &args[3], &dest).map_err(|_| {
        format!(
            "quarantined tree changed after ownership verification; data retained at {}",
            quarantine.display()
        )
    })?;
    if fs::symlink_metadata(&dest).is_ok() {
        return Err(format!(
            "public destination was replaced; quarantined data retained at {}",
            quarantine.display()
        )
        .into());
    }

    publish_record(current_state, &states, &transaction)?;
    inject_failure(
        "VIBEGUARD_TEST_QUARANTINE_AFTER_STATE",
        "injected failure after install-state publish",
    )?;
    transaction.phase = "committed".into();
    write_json_durable(&transaction_path, &transaction_value(&transaction))?;
    println!("QUARANTINED\t{}", quarantine.display());
    Ok(())
}

pub fn release(args: &[String]) -> SetupResult<()> {
    if args.len() != 4 {
        return Err(RELEASE_USAGE.into());
    }
    let current_state = Path::new(&args[0]);
    let previous_state = Path::new(&args[1]);
    let states = [current_state, previous_state];
    let dest = absolute(Path::new(&args[2]));
    let parent = dest
        .parent()
        .ok_or("managed tree has no parent directory")?;
    let name = dest
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .ok_or("managed tree name must be non-empty UTF-8")?;
    let Some(record) = active_record(&states, &dest)? else {
        println!("ABSENT");
        return Ok(());
    };
    verify_exact(&states, &dest, &args[3], &dest)?;

    let mut matched = None;
    for transaction_path in transaction_paths(parent, name)? {
        let transaction = read_transaction(&transaction_path)?;
        validate_transaction(
            &transaction,
            &transaction_path,
            &dest,
            parent,
            name,
            Some(&args[3]),
        )?;
        if record_value(&transaction) != record {
            continue;
        }
        if matched.is_some() {
            return Err("multiple quarantine transactions match the active record".into());
        }
        matched = Some((transaction_path, transaction));
    }
    let (transaction_path, mut transaction) =
        matched.ok_or("active quarantine record has no exact durable transaction")?;
    if transaction.phase != "committed"
        && transaction.phase != "intent"
        && transaction.phase != "released"
    {
        return Err("active quarantine transaction is not releasable".into());
    }
    let quarantine = Path::new(&transaction.quarantine);
    let metadata = fs::symlink_metadata(quarantine)
        .map_err(|error| format!("quarantine retention cannot be proven: {error}"))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err("quarantine retention path is not a regular directory".into());
    }

    transaction.phase = "released".into();
    write_json_durable(&transaction_path, &transaction_value(&transaction))?;
    inject_failure(
        "VIBEGUARD_TEST_RELEASE_AFTER_TRANSACTION",
        "injected failure after quarantine release transaction",
    )?;
    let current_removed = remove_record(current_state, &dest, &record)?;
    let previous_removed = remove_record(previous_state, &dest, &record)?;
    if !current_removed && !previous_removed {
        return Err("active quarantine record changed before release".into());
    }
    println!("RELEASED");
    Ok(())
}

fn recover_or_find_committed(
    states: &[&Path; 2],
    current_state: &Path,
    dest: &Path,
    parent: &Path,
    name: &str,
    source_prefix: &str,
) -> SetupResult<Option<PathBuf>> {
    let active_record = active_record(states, dest)?;
    let mut committed = None;
    for transaction_path in transaction_paths(parent, name)? {
        let mut transaction = read_transaction(&transaction_path)?;
        let expected_source = (!matches!(transaction.phase.as_str(), "restored" | "released"))
            .then_some(source_prefix);
        validate_transaction(
            &transaction,
            &transaction_path,
            dest,
            parent,
            name,
            expected_source,
        )?;
        let record_matches = active_record
            .as_ref()
            .is_some_and(|record| record == &record_value(&transaction));
        let quarantine = PathBuf::from(&transaction.quarantine);
        match transaction.phase.as_str() {
            "intent" if record_matches => {
                ensure_public_absent(dest)?;
                verify_exact(states, &quarantine, source_prefix, dest)?;
                transaction.phase = "committed".into();
                write_json_durable(&transaction_path, &transaction_value(&transaction))?;
                publish_record(current_state, states, &transaction)?;
                committed = Some(quarantine);
            }
            "intent" => {
                recover_intent(states, dest, parent, source_prefix, &quarantine)?;
                transaction.phase = "restored".into();
                write_json_durable(&transaction_path, &transaction_value(&transaction))?;
            }
            "committed" if record_matches => {
                ensure_public_absent(dest)?;
                verify_exact(states, &quarantine, source_prefix, dest)?;
                publish_record(current_state, states, &transaction)?;
                committed = Some(quarantine);
            }
            "committed" | "restored" | "released" => {}
            phase => return Err(format!("unknown managed-tree transaction phase: {phase}").into()),
        }
    }
    if active_record.is_some() && committed.is_none() {
        return Err("install-state quarantine locator has no exact transaction".into());
    }
    Ok(committed)
}

fn recover_intent(
    states: &[&Path; 2],
    dest: &Path,
    parent: &Path,
    source_prefix: &str,
    quarantine: &Path,
) -> SetupResult<()> {
    let public_exists = fs::symlink_metadata(dest).is_ok();
    let quarantine_exists = fs::symlink_metadata(quarantine).is_ok();
    match (public_exists, quarantine_exists) {
        (false, true) => {
            verify_exact(states, quarantine, source_prefix, dest).map_err(|_| {
                format!(
                    "uncommitted quarantine changed; refusing recovery and retaining {}",
                    quarantine.display()
                )
            })?;
            rename_noreplace(quarantine, dest).map_err(|error| {
                format!(
                    "failed to restore uncommitted quarantine without replacement: {error}; data retained at {}",
                    quarantine.display()
                )
            })?;
            sync_directory(parent)?;
            verify_exact(states, dest, source_prefix, dest)?;
            Ok(())
        }
        (true, false) => verify_exact(states, dest, source_prefix, dest),
        (true, true) => Err(format!(
            "recovery collision: public and quarantine paths both exist; retained {}",
            quarantine.display()
        )
        .into()),
        (false, false) => Err("transaction paths are both missing; refusing recovery".into()),
    }
}

fn reserve_transaction(
    dest: &Path,
    parent: &Path,
    name: &str,
    source_prefix: &str,
    tracked_digest: &str,
    generation: u64,
) -> SetupResult<Transaction> {
    for attempt in 1..=10 {
        let nonce = format!("{}-{}-{attempt}", std::process::id(), now_nanos());
        let quarantine = parent.join(format!(".{name}.vibeguard-quarantine.{nonce}"));
        let transaction = parent.join(format!(".{name}.vibeguard-transaction.{nonce}.json"));
        inject_collision(&quarantine)?;
        if fs::symlink_metadata(&quarantine).is_ok() || fs::symlink_metadata(&transaction).is_ok() {
            continue;
        }
        return Ok(Transaction {
            version: TRANSACTION_VERSION,
            phase: "intent".into(),
            dest: path_text(dest),
            quarantine: path_text(&quarantine),
            transaction: path_text(&transaction),
            source_prefix: source_prefix.into(),
            tracked_digest: tracked_digest.into(),
            install_state_generation: generation,
            nonce,
        });
    }
    Err(format!(
        "failed to reserve unique quarantine for managed tree: {}",
        dest.display()
    )
    .into())
}

fn owned_digest(
    states: &[&Path; 2],
    actual: &Path,
    source_prefix: &str,
    tracked_dest: &Path,
) -> SetupResult<Option<String>> {
    let mut digest = None;
    for state_path in states {
        if !state_path.exists()
            || managed_tree_decision(state_path, actual, source_prefix, tracked_dest)? != "OWNED"
        {
            continue;
        }
        let state = read_state(state_path)?;
        let files = state["files"]
            .as_object()
            .ok_or("install-state files must be an object")?;
        let mut tracked = BTreeMap::new();
        for (path, entry) in files {
            let expanded = absolute(Path::new(path));
            if expanded == tracked_dest || expanded.starts_with(tracked_dest) {
                tracked.insert(path, entry);
            }
        }
        let canonical = serde_json::to_string(&tracked)?;
        let candidate = format!("sha256:{}", sha256_text(&canonical));
        if digest.as_ref().is_some_and(|value| value != &candidate) {
            return Err("install-state generations disagree on managed-tree digest".into());
        }
        digest = Some(candidate);
    }
    Ok(digest)
}

fn verify_exact(
    states: &[&Path; 2],
    actual: &Path,
    source_prefix: &str,
    tracked_dest: &Path,
) -> SetupResult<()> {
    if owned_digest(states, actual, source_prefix, tracked_dest)?.is_none() {
        return Err(format!(
            "managed tree is not an exact VibeGuard-owned copy: {}",
            actual.display()
        )
        .into());
    }
    Ok(())
}

fn active_record(states: &[&Path; 2], dest: &Path) -> SetupResult<Option<Value>> {
    let mut record = None;
    let dest_text = path_text(dest);
    for state_path in states {
        if !state_path.exists() {
            continue;
        }
        let state = read_state(state_path)?;
        validate_state_metadata(&state)?;
        let candidate = state
            .get("disabled_skill_quarantines")
            .and_then(Value::as_object)
            .and_then(|records| records.get(&dest_text))
            .cloned();
        if let Some(candidate) = candidate {
            if record.as_ref().is_some_and(|value| value != &candidate) {
                return Err("install-state generations disagree on quarantine locator".into());
            }
            record = Some(candidate);
        }
    }
    Ok(record)
}

fn publish_record(
    state_path: &Path,
    states: &[&Path; 2],
    transaction: &Transaction,
) -> SetupResult<()> {
    let mut state = read_state(state_path)?;
    validate_state_metadata(&state)?;
    carry_tracked_files(&mut state, states, Path::new(&transaction.dest))?;
    let state_object = state
        .as_object_mut()
        .ok_or("install-state root must be an object")?;
    let records = state_object
        .entry("disabled_skill_quarantines")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or("disabled_skill_quarantines must be an object")?;
    let record = record_value(transaction);
    if let Some(existing) = records.get(&transaction.dest)
        && existing != &record
    {
        return Err("refusing to replace a different quarantine locator".into());
    }
    records.insert(transaction.dest.clone(), record);
    write_json_atomic(state_path, &state)?;
    sync_parent(state_path)
}

fn remove_record(state_path: &Path, dest: &Path, expected: &Value) -> SetupResult<bool> {
    if !state_path.exists() {
        return Ok(false);
    }
    let mut state = read_state(state_path)?;
    validate_state_metadata(&state)?;
    let state_object = state
        .as_object_mut()
        .ok_or("install-state root must be an object")?;
    let Some(records) = state_object
        .get_mut("disabled_skill_quarantines")
        .and_then(Value::as_object_mut)
    else {
        return Ok(false);
    };
    let dest_text = path_text(dest);
    let Some(actual) = records.get(&dest_text) else {
        return Ok(false);
    };
    if actual != expected {
        return Err("active quarantine record changed before release".into());
    }
    records.remove(&dest_text);
    if records.is_empty() {
        state_object.remove("disabled_skill_quarantines");
    }
    write_json_atomic(state_path, &state)?;
    sync_parent(state_path)?;
    Ok(true)
}

fn record_value(transaction: &Transaction) -> Value {
    json!({
        "version": transaction.version,
        "quarantine": transaction.quarantine,
        "transaction": transaction.transaction,
        "source_prefix": transaction.source_prefix,
        "tracked_digest": transaction.tracked_digest,
        "install_state_generation": transaction.install_state_generation,
        "nonce": transaction.nonce,
    })
}

fn transaction_value(transaction: &Transaction) -> Value {
    json!({
        "version": transaction.version,
        "phase": transaction.phase,
        "dest": transaction.dest,
        "quarantine": transaction.quarantine,
        "transaction": transaction.transaction,
        "source_prefix": transaction.source_prefix,
        "tracked_digest": transaction.tracked_digest,
        "install_state_generation": transaction.install_state_generation,
        "nonce": transaction.nonce,
    })
}

pub(crate) fn validate_state_metadata(state: &Value) -> SetupResult<()> {
    let Some(records) = state.get("disabled_skill_quarantines") else {
        return Ok(());
    };
    let records = records
        .as_object()
        .ok_or("disabled_skill_quarantines must be an object")?;
    for (dest, record) in records {
        let record = record
            .as_object()
            .ok_or("disabled skill quarantine record must be an object")?;
        tree_state::validate_record(dest, record)?;
    }
    Ok(())
}

fn validate_transaction(
    transaction: &Transaction,
    path: &Path,
    dest: &Path,
    parent: &Path,
    name: &str,
    source_prefix: Option<&str>,
) -> SetupResult<()> {
    if transaction.version != TRANSACTION_VERSION
        || transaction.dest != path_text(dest)
        || transaction.transaction != path_text(path)
        || source_prefix.is_some_and(|expected| transaction.source_prefix != expected)
        || !valid_digest(&Value::String(transaction.tracked_digest.clone()))
        || transaction.nonce.is_empty()
    {
        return Err(format!(
            "managed-tree transaction does not match request: {}",
            path.display()
        )
        .into());
    }
    let quarantine = Path::new(&transaction.quarantine);
    let expected_transaction = parent.join(format!(
        ".{name}.vibeguard-transaction.{}.json",
        transaction.nonce
    ));
    let expected_quarantine = parent.join(format!(
        ".{name}.vibeguard-quarantine.{}",
        transaction.nonce
    ));
    if path != expected_transaction || quarantine != expected_quarantine {
        return Err("managed-tree transaction contains an unknown path".into());
    }
    Ok(())
}

fn transaction_paths(parent: &Path, name: &str) -> SetupResult<Vec<PathBuf>> {
    let prefix = format!(".{name}.vibeguard-transaction.");
    let mut paths = Vec::new();
    for entry in fs::read_dir(parent)? {
        let path = entry?.path();
        if !path
            .file_name()
            .and_then(|value| value.to_str())
            .is_some_and(|value| value.starts_with(&prefix))
        {
            continue;
        }
        let metadata = fs::symlink_metadata(&path)?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(format!(
                "managed-tree transaction path is not a regular file: {}",
                path.display()
            )
            .into());
        }
        paths.push(path);
    }
    paths.sort();
    Ok(paths)
}

fn read_transaction(path: &Path) -> SetupResult<Transaction> {
    let value: Value = serde_json::from_slice(&fs::read(path)?)?;
    let object = value
        .as_object()
        .ok_or("managed-tree transaction root must be an object")?;
    let expected = [
        "dest",
        "install_state_generation",
        "nonce",
        "phase",
        "quarantine",
        "source_prefix",
        "tracked_digest",
        "transaction",
        "version",
    ];
    if object.len() != expected.len() || expected.iter().any(|key| !object.contains_key(*key)) {
        return Err("managed-tree transaction has unknown or missing fields".into());
    }
    Ok(Transaction {
        version: object["version"]
            .as_u64()
            .ok_or("managed-tree transaction version must be an integer")?,
        phase: required_string(object, "phase")?,
        dest: required_string(object, "dest")?,
        quarantine: required_string(object, "quarantine")?,
        transaction: required_string(object, "transaction")?,
        source_prefix: required_string(object, "source_prefix")?,
        tracked_digest: required_string(object, "tracked_digest")?,
        install_state_generation: object["install_state_generation"]
            .as_u64()
            .ok_or("managed-tree transaction generation must be an integer")?,
        nonce: required_string(object, "nonce")?,
    })
}

fn required_string(object: &Map<String, Value>, key: &str) -> SetupResult<String> {
    object[key]
        .as_str()
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| format!("managed-tree transaction {key} must be a non-empty string").into())
}

fn current_generation(path: &Path) -> SetupResult<u64> {
    let state = read_state(path)?;
    validate_state_metadata(&state)?;
    match (state.get("generation"), state.get("complete")) {
        (None, None) => Ok(0),
        (Some(generation), Some(complete)) if complete.as_bool().is_some() => generation
            .as_u64()
            .filter(|value| *value > 0)
            .ok_or_else(|| "install-state generation must be a positive integer".into()),
        _ => Err("install-state generation and complete must be declared together".into()),
    }
}

fn write_new_json_durable(path: &Path, value: &Value) -> SetupResult<()> {
    let tmp = path.with_extension(format!("tmp.{}.{}", std::process::id(), now_nanos()));
    let bytes = serde_json::to_vec_pretty(value)?;
    let result = (|| {
        let mut file = OpenOptions::new().write(true).create_new(true).open(&tmp)?;
        file.write_all(&bytes)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        rename_noreplace(&tmp, path)?;
        sync_parent(path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

fn write_json_durable(path: &Path, value: &Value) -> SetupResult<()> {
    write_json_atomic(path, value)?;
    sync_parent(path)
}

fn sync_parent(path: &Path) -> SetupResult<()> {
    sync_directory(path.parent().ok_or("durable path has no parent")?)
}

fn sync_directory(path: &Path) -> SetupResult<()> {
    #[cfg(unix)]
    File::open(path)?.sync_all()?;
    #[cfg(windows)]
    let _ = path;
    Ok(())
}

fn ensure_public_absent(dest: &Path) -> SetupResult<()> {
    match fs::symlink_metadata(dest) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Ok(_) => Err(format!(
            "disabled public destination unexpectedly exists: {}",
            dest.display()
        )
        .into()),
        Err(error) => Err(error.into()),
    }
}

fn valid_text(value: &Value) -> bool {
    value
        .as_str()
        .is_some_and(|text| !text.is_empty() && !text.contains(['\n', '\r']))
}

fn valid_digest(value: &Value) -> bool {
    value
        .as_str()
        .and_then(|text| text.strip_prefix("sha256:"))
        .is_some_and(|digest| {
            digest.len() == 64
                && digest
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        })
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn rename_noreplace(from: &Path, to: &Path) -> io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let from = CString::new(from.as_os_str().as_bytes())?;
    let to = CString::new(to.as_os_str().as_bytes())?;
    let result = unsafe {
        libc::renameat2(
            libc::AT_FDCWD,
            from.as_ptr(),
            libc::AT_FDCWD,
            to.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn rename_noreplace(from: &Path, to: &Path) -> io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let from = CString::new(from.as_os_str().as_bytes())?;
    let to = CString::new(to.as_os_str().as_bytes())?;
    let result = unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(windows)]
fn rename_noreplace(from: &Path, to: &Path) -> io::Result<()> {
    match fs::rename(from, to) {
        Ok(()) => Ok(()),
        Err(_) if fs::symlink_metadata(to).is_ok() => Err(io::ErrorKind::AlreadyExists.into()),
        Err(error) => Err(error),
    }
}

#[cfg(not(any(
    target_os = "linux",
    target_os = "android",
    target_os = "macos",
    target_os = "ios",
    windows
)))]
fn rename_noreplace(_from: &Path, _to: &Path) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "atomic no-replace rename is unsupported",
    ))
}

fn absolute(path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    }
}

fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn now_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}
