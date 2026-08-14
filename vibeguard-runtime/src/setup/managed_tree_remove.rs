use crate::setup::install_state::read_state;
use crate::setup::support::{SetupResult, write_json_atomic};
use serde_json::{Map, Value, json};
use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};

#[path = "managed_tree_test_support.rs"]
mod test_support;
#[path = "managed_tree_io.rs"]
mod tree_io;
#[path = "managed_tree_state.rs"]
pub(crate) mod tree_state;
use test_support::{
    inject_collision, inject_failure, inject_postverify, inject_public_replacement,
};
use tree_io::{
    absolute, ensure_public_absent, path_text, sync_parent, valid_digest, valid_text,
    write_json_durable, write_new_json_durable,
};
pub(crate) use tree_io::{now_nanos, rename_noreplace, sync_directory};
use tree_state::{carry_tracked_files, managed_tree_decision};

const USAGE: &str = "Usage: vibeguard-runtime setup-state-quarantine-managed-tree <state-file> <previous-state-file> <dest-dir> <source-prefix>";
const RELEASE_USAGE: &str = "Usage: vibeguard-runtime setup-state-release-quarantined-tree <state-file> <previous-state-file> <dest-dir> <source-prefix>";
const VALIDATE_TRANSACTIONS_USAGE: &str = "Usage: vibeguard-runtime setup-state-validate-managed-tree-transactions <skills-dir> [state-file previous-state-file]";
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
    let mut matched = None;
    for transaction_path in transaction_paths(parent, name)? {
        let transaction = read_transaction(&transaction_path)?;
        let record_matches = record_value(&transaction) == record;
        // A matching active record proves which historical source prefix owns
        // the retained quarantine. Re-enable still verifies the newly restored
        // public tree against the request's current prefix below.
        let expected_source = (!record_matches
            && !matches!(transaction.phase.as_str(), "restored" | "released"))
        .then_some(args[3].as_str());
        validate_transaction(
            &transaction,
            &transaction_path,
            &dest,
            parent,
            name,
            expected_source,
        )?;
        if !record_matches {
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
    tree_state::prune_missing_tracked_files(current_state, &dest)?;
    verify_exact(&states, &dest, &args[3], &dest)?;

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

pub fn validate_transactions(args: &[String]) -> SetupResult<()> {
    if args.len() != 1 && args.len() != 3 {
        return Err(VALIDATE_TRANSACTIONS_USAGE.into());
    }
    let directory = absolute(Path::new(&args[0]));
    let clean_states = (args.len() == 3).then(|| [Path::new(&args[1]), Path::new(&args[2])]);
    match fs::symlink_metadata(&directory) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            return Err("managed-tree transaction root must be a directory or absent".into());
        }
        Ok(_) => {}
    }
    for entry in fs::read_dir(&directory)? {
        let path = entry?.path();
        let Some(file_name) = path.file_name().and_then(|value| value.to_str()) else {
            continue;
        };
        let Some((name, nonce)) = file_name
            .strip_prefix('.')
            .and_then(|value| value.strip_suffix(".json"))
            .and_then(|value| value.rsplit_once(".vibeguard-transaction."))
        else {
            continue;
        };
        if name.is_empty() || nonce.is_empty() {
            continue;
        }
        let mut name_components = Path::new(name).components();
        if !matches!(
            (name_components.next(), name_components.next()),
            (Some(Component::Normal(_)), None)
        ) {
            return Err(format!(
                "managed-tree transaction name must be one normal path component: {name}"
            )
            .into());
        }
        let metadata = fs::symlink_metadata(&path)?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(format!(
                "managed-tree transaction path is not a regular file: {}",
                path.display()
            )
            .into());
        }
        let transaction = read_transaction(&path)?;
        if !matches!(
            transaction.phase.as_str(),
            "intent" | "committed" | "restored" | "released"
        ) {
            return Err(format!(
                "managed-tree transaction phase is unsupported: {}",
                transaction.phase
            )
            .into());
        }
        // The canonical filename and caller-owned skills root define the only
        // destination this transaction may describe. Deriving the expected
        // value from transaction.dest would let an untrusted record self-attest
        // an out-of-root destination.
        let dest = directory.join(name);
        validate_transaction(&transaction, &path, &dest, &directory, name, None)?;
        if transaction.phase == "intent"
            && let Some(states) = clean_states.as_ref()
            && active_record(states, &dest)?.as_ref() != Some(&record_value(&transaction))
        {
            return Err(format!(
                "clean cannot discard an unreferenced active quarantine intent: {}",
                path.display()
            )
            .into());
        }
    }
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
    let mut active_record = active_record(states, dest)?;
    let mut committed = None;
    for transaction_path in transaction_paths(parent, name)? {
        let mut transaction = read_transaction(&transaction_path)?;
        let record_matches = active_record
            .as_ref()
            .is_some_and(|record| record == &record_value(&transaction));
        // An active quarantine's stored source prefix is historical evidence
        // that install-state preflight already validated. When a later manifest
        // moves a disabled skill's source directory while keeping its public
        // name, forcing the request's new prefix here would abort every install
        // and re-enable after setup already refreshed the installed snapshot.
        // Terminal phases have no live source left to prove at all.
        let expected_source = (!record_matches
            && !matches!(transaction.phase.as_str(), "restored" | "released"))
        .then_some(source_prefix);
        validate_transaction(
            &transaction,
            &transaction_path,
            dest,
            parent,
            name,
            expected_source,
        )?;
        // Ownership of an active quarantine must likewise be proven against the
        // prefix its tracked inventory was recorded under, not the moved path.
        let owner_source = if record_matches {
            transaction.source_prefix.clone()
        } else {
            source_prefix.to_string()
        };
        let quarantine = PathBuf::from(&transaction.quarantine);
        match transaction.phase.as_str() {
            "intent" if record_matches => {
                ensure_public_absent(dest)?;
                verify_exact(states, &quarantine, &owner_source, dest)?;
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
                verify_exact(states, &quarantine, &owner_source, dest)?;
                publish_record(current_state, states, &transaction)?;
                committed = Some(quarantine);
            }
            "released" if record_matches => {
                // A release that persisted its released phase but failed before
                // removing the active state record must be finished here.
                // Leaving the stale record behind makes the exactness check
                // below reject every later disable of this skill.
                let record = record_value(&transaction);
                let mut removed = false;
                for state_path in states {
                    removed |= remove_record(state_path, dest, &record)?;
                }
                if !removed {
                    return Err("interrupted quarantine release could not be completed".into());
                }
                active_record = None;
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
        let candidate = tree_state::tracked_inventory_digest(&state, tracked_dest)?
            .ok_or("owned managed tree has no tracked inventory")?;
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

pub(crate) fn validate_state_artifacts(state: &Value) -> SetupResult<()> {
    validate_state_artifacts_with_released_inventory(state, state)
}

pub(crate) fn validate_state_artifacts_with_released_inventory(
    state: &Value,
    released_inventory: &Value,
) -> SetupResult<()> {
    let Some(records) = state
        .get("disabled_skill_quarantines")
        .and_then(Value::as_object)
    else {
        return Ok(());
    };
    for (dest, record) in records {
        let record = record
            .as_object()
            .ok_or("disabled skill quarantine record must be an object")?;
        tree_state::validate_record_artifacts(dest, record, state, released_inventory)?;
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
        if path
            .file_name()
            .and_then(|value| value.to_str())
            .and_then(|value| value.strip_prefix(&prefix))
            .and_then(|value| value.strip_suffix(".json"))
            .is_none_or(|nonce| nonce.is_empty())
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
