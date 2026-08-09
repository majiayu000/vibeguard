use crate::setup_install_state::{
    ensure_state_version, expand_home, read_state, setup_absolute_path,
};
use crate::setup_support::{SetupResult, home_dir, sha256_file, sha256_text, write_json_atomic};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Component, Path, PathBuf};

use super::{TRANSACTION_VERSION, absolute, valid_digest, valid_text};

pub(super) fn carry_tracked_files(
    target: &mut Value,
    source_states: &[&Path; 2],
    tracked_dest: &Path,
) -> SetupResult<()> {
    let mut carried = BTreeMap::new();
    for source_path in source_states {
        if !source_path.exists() {
            continue;
        }
        let source = read_state(source_path)?;
        let files = source["files"]
            .as_object()
            .ok_or("install-state files must be an object")?;
        for (path, entry) in files {
            let expanded = setup_absolute_path(&expand_home(path));
            if expanded != tracked_dest && !expanded.starts_with(tracked_dest) {
                continue;
            }
            if carried
                .insert(path.clone(), entry.clone())
                .is_some_and(|previous| previous != *entry)
            {
                return Err(
                    "install-state generations disagree on tracked quarantine files".into(),
                );
            }
        }
    }
    if carried.is_empty() {
        return Err("quarantine publication has no exact tracked file inventory".into());
    }
    let target_files = target["files"]
        .as_object_mut()
        .ok_or("install-state files must be an object")?;
    for (path, entry) in carried {
        if target_files
            .insert(path, entry.clone())
            .is_some_and(|previous| previous != entry)
        {
            return Err("current install state conflicts with quarantine inventory".into());
        }
    }
    Ok(())
}

pub(super) fn validate_record(dest: &str, record: &Map<String, Value>) -> SetupResult<()> {
    let expected = [
        "install_state_generation",
        "nonce",
        "quarantine",
        "source_prefix",
        "tracked_digest",
        "transaction",
        "version",
    ];
    if record.len() != expected.len() || expected.iter().any(|key| !record.contains_key(*key)) {
        return Err("disabled skill quarantine record has unknown or missing fields".into());
    }
    if record["version"].as_u64() != Some(TRANSACTION_VERSION)
        || record["install_state_generation"].as_u64().is_none()
        || !valid_text(&record["nonce"])
        || !valid_text(&record["source_prefix"])
        || !valid_digest(&record["tracked_digest"])
    {
        return Err("disabled skill quarantine record has invalid scalar fields".into());
    }
    let dest = absolute(Path::new(dest));
    let parent = dest
        .parent()
        .ok_or("quarantine record destination has no parent")?;
    let name = dest
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .ok_or("quarantine record destination name must be non-empty UTF-8")?;
    let nonce = record["nonce"]
        .as_str()
        .ok_or("quarantine record nonce must be a string")?;
    let quarantine = record["quarantine"]
        .as_str()
        .map(Path::new)
        .ok_or("quarantine locator must be a string")?;
    let transaction = record["transaction"]
        .as_str()
        .map(Path::new)
        .ok_or("quarantine locator must be a string")?;
    if quarantine != parent.join(format!(".{name}.vibeguard-quarantine.{nonce}"))
        || transaction != parent.join(format!(".{name}.vibeguard-transaction.{nonce}.json"))
    {
        return Err("quarantine locator does not match its nonce".into());
    }
    Ok(())
}

/// Correct locator strings do not prove the durable artifacts they name still
/// exist and describe this record. Preflight must reject a deleted or corrupted
/// quarantine before setup resets install-state or mutates Claude/Codex assets,
/// instead of leaving it for transaction recovery to abort on.
pub(super) fn validate_record_artifacts(
    dest: &str,
    record: &Map<String, Value>,
    state: &Value,
    released_inventory: &Value,
) -> SetupResult<()> {
    let quarantine = record["quarantine"]
        .as_str()
        .map(Path::new)
        .ok_or("quarantine locator must be a string")?;
    let transaction_path = record["transaction"]
        .as_str()
        .map(Path::new)
        .ok_or("quarantine locator must be a string")?;

    let metadata = fs::symlink_metadata(quarantine).map_err(|error| {
        format!(
            "active quarantine directory cannot be proven for {dest}: {error}; retained {}",
            quarantine.display()
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(format!(
            "active quarantine path is not a directory: {}",
            quarantine.display()
        )
        .into());
    }
    let metadata = fs::symlink_metadata(transaction_path).map_err(|error| {
        format!(
            "active quarantine transaction cannot be proven for {dest}: {error}; retained {}",
            quarantine.display()
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(format!(
            "active quarantine transaction is not a regular file: {}",
            transaction_path.display()
        )
        .into());
    }

    let value: Value = serde_json::from_slice(&fs::read(transaction_path)?).map_err(|error| {
        format!(
            "active quarantine transaction is unreadable for {dest}: {error}; retained {}",
            quarantine.display()
        )
    })?;
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
    if object.get("dest").and_then(Value::as_str) != Some(dest) {
        return Err(format!(
            "active quarantine transaction names another destination: {}",
            transaction_path.display()
        )
        .into());
    }
    let phase = object
        .get("phase")
        .and_then(Value::as_str)
        .ok_or("active quarantine transaction has no phase")?;
    if !matches!(phase, "intent" | "committed" | "released") {
        return Err(
            format!("active quarantine transaction phase is not recoverable: {phase}").into(),
        );
    }
    for key in [
        "version",
        "quarantine",
        "transaction",
        "source_prefix",
        "tracked_digest",
        "install_state_generation",
        "nonce",
    ] {
        if object.get(key) != record.get(key) {
            return Err(format!(
                "active quarantine transaction does not match its record field {key}: {}",
                transaction_path.display()
            )
            .into());
        }
    }
    if matches!(phase, "intent" | "committed") {
        validate_active_quarantine_tree(state, Path::new(dest), quarantine, record)?;
    }
    match fs::symlink_metadata(dest) {
        Ok(_) if phase != "released" => {
            return Err(format!("disabled public destination unexpectedly exists: {dest}").into());
        }
        Ok(_) => validate_released_public_tree(released_inventory, Path::new(dest))?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    Ok(())
}

fn validate_active_quarantine_tree(
    state: &Value,
    dest: &Path,
    quarantine: &Path,
    record: &Map<String, Value>,
) -> SetupResult<()> {
    let dest = setup_absolute_path(dest);
    let source_prefix = record["source_prefix"]
        .as_str()
        .ok_or("active quarantine record has no source prefix")?;
    let decision = managed_tree_decision_for_state(state, quarantine, source_prefix, &dest)?;
    if decision != "OWNED" {
        return Err(
            format!("active quarantine is not an exact VibeGuard-owned tree: {decision}").into(),
        );
    }
    let actual_digest = tracked_inventory_digest(state, &dest)?
        .ok_or("active quarantine has no tracked file inventory")?;
    if record["tracked_digest"].as_str() != Some(actual_digest.as_str()) {
        return Err("active quarantine tracked digest does not match canonical inventory".into());
    }
    Ok(())
}

pub(super) fn tracked_inventory_digest(
    state: &Value,
    tracked_dest: &Path,
) -> SetupResult<Option<String>> {
    let files = state["files"]
        .as_object()
        .ok_or("install-state files must be an object")?;
    let tracked = files
        .iter()
        .filter(|(path, _)| {
            let expanded = setup_absolute_path(&expand_home(path));
            expanded == tracked_dest || expanded.starts_with(tracked_dest)
        })
        .collect::<BTreeMap<_, _>>();
    if tracked.is_empty() {
        return Ok(None);
    }
    let canonical = serde_json::to_string(&tracked)?;
    Ok(Some(format!("sha256:{}", sha256_text(&canonical))))
}

pub(crate) fn intent_quarantine_for_dest(dest: &Path) -> SetupResult<Option<PathBuf>> {
    let dest = setup_absolute_path(dest);
    let parent = dest
        .parent()
        .ok_or("managed tree has no parent directory")?;
    let name = dest
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .ok_or("managed tree name must be non-empty UTF-8")?;
    let prefix = format!(".{name}.vibeguard-transaction.");
    let mut found = None;
    for entry in fs::read_dir(parent)? {
        let path = entry?.path();
        let Some(nonce) = path
            .file_name()
            .and_then(|value| value.to_str())
            .and_then(|value| value.strip_prefix(&prefix))
            .and_then(|value| value.strip_suffix(".json"))
            .filter(|value| !value.is_empty())
        else {
            continue;
        };
        let value: Value = serde_json::from_slice(&fs::read(&path)?)?;
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
        if object.get("phase").and_then(Value::as_str) != Some("intent") {
            continue;
        }
        let quarantine = parent.join(format!(".{name}.vibeguard-quarantine.{nonce}"));
        if object.get("dest").and_then(Value::as_str) != dest.to_str()
            || object.get("nonce").and_then(Value::as_str) != Some(nonce)
            || object.get("transaction").and_then(Value::as_str) != path.to_str()
            || object.get("quarantine").and_then(Value::as_str) != quarantine.to_str()
        {
            return Err("managed-tree intent transaction contains an unknown path".into());
        }
        let metadata = fs::symlink_metadata(&quarantine)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err("managed-tree intent quarantine is not a directory".into());
        }
        if found.replace(quarantine).is_some() {
            return Err("multiple intent quarantines match managed tree".into());
        }
    }
    Ok(found)
}

/// Recover the locator that would have been published immediately after an
/// intent rename. A later manifest may no longer enumerate the skill, so the
/// install loop cannot be relied on to revisit its public destination. Only an
/// intent whose hidden tree is an exact match for this state's tracked
/// inventory is eligible for carry.
pub(crate) fn orphan_intent_records(state: &Value) -> SetupResult<Map<String, Value>> {
    let Some(home) = home_dir() else {
        return Ok(Map::new());
    };
    let directory = setup_absolute_path(&home.join(".codex/skills"));
    match fs::symlink_metadata(&directory) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Map::new()),
        Err(error) => return Err(error.into()),
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            return Err("managed-tree transaction root must be a directory or absent".into());
        }
        Ok(_) => {}
    }
    let active = state
        .get("disabled_skill_quarantines")
        .and_then(Value::as_object);
    let mut records = Map::new();
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
        let mut components = Path::new(name).components();
        if !matches!(
            (components.next(), components.next()),
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
        let transaction = super::read_transaction(&path)?;
        if transaction.phase != "intent" {
            continue;
        }
        let dest = directory.join(name);
        super::validate_transaction(&transaction, &path, &dest, &directory, name, None)?;
        let dest_text = super::path_text(&dest);
        if active.is_some_and(|active| active.contains_key(&dest_text))
            || tracked_inventory_digest(state, &dest)?.is_none()
        {
            continue;
        }
        let record = super::record_value(&transaction);
        validate_record_artifacts(
            &dest_text,
            record
                .as_object()
                .ok_or("durable quarantine intent record must be an object")?,
            state,
            state,
        )?;
        if records
            .insert(dest_text, record.clone())
            .is_some_and(|previous| previous != record)
        {
            return Err("multiple durable quarantine intents match tracked inventory".into());
        }
    }
    Ok(records)
}

pub(super) fn prune_missing_tracked_files(state_path: &Path, dest: &Path) -> SetupResult<()> {
    let mut state = read_state(state_path)?;
    let files = state["files"]
        .as_object_mut()
        .ok_or("install-state files must be an object")?;
    let before = files.len();
    files.retain(|path, _| {
        let path = setup_absolute_path(&expand_home(path));
        (path != dest && !path.starts_with(dest)) || fs::symlink_metadata(path).is_ok()
    });
    if files.len() != before {
        write_json_atomic(state_path, &state)?;
        super::sync_directory(state_path.parent().ok_or("install-state has no parent")?)?;
    }
    Ok(())
}

fn validate_released_public_tree(state: &Value, dest: &Path) -> SetupResult<()> {
    let files = state["files"]
        .as_object()
        .ok_or("install-state files must be an object")?;
    let mut leaves = Vec::new();
    collect_regular_leaves(dest, &mut leaves)?;
    if leaves.is_empty() {
        return Err("released quarantine public tree has no tracked inventory".into());
    }
    for path in leaves {
        let entry = files
            .iter()
            .find(|(tracked, _)| setup_absolute_path(&expand_home(tracked)) == path)
            .map(|(_, entry)| entry)
            .ok_or("released quarantine public tree contains an untracked path")?;
        let metadata = fs::symlink_metadata(&path)?;
        if metadata.file_type().is_symlink()
            || !metadata.is_file()
            || entry.get("type").and_then(Value::as_str) != Some("copy")
        {
            return Err("released quarantine public tree has an unsupported path".into());
        }
        let expected = entry
            .get("checksum")
            .and_then(Value::as_str)
            .ok_or("released quarantine public file has no checksum")?;
        if format!("sha256:{}", sha256_file(&path)?) != expected {
            return Err("released quarantine public tree checksum does not match state".into());
        }
    }
    Ok(())
}

fn collect_regular_leaves(directory: &Path, leaves: &mut Vec<PathBuf>) -> SetupResult<()> {
    for entry in fs::read_dir(directory)? {
        let path = entry?.path();
        let metadata = fs::symlink_metadata(&path)?;
        if metadata.file_type().is_symlink() || (!metadata.is_file() && !metadata.is_dir()) {
            return Err("released quarantine public tree has an unsupported path".into());
        }
        if metadata.is_dir() {
            collect_regular_leaves(&path, leaves)?;
        } else {
            leaves.push(path);
        }
    }
    Ok(())
}

pub fn verify_managed_tree(args: &[String]) -> SetupResult<()> {
    if args.len() != 3 && args.len() != 4 {
        return Err(
            "Usage: vibeguard-runtime setup-state-verify-managed-tree <state-file> <dest-dir> <source-prefix> [tracked-dest-dir]"
                .into(),
        );
    }
    let state_file = Path::new(&args[0]);
    let dest_dir = setup_absolute_path(&expand_home(&args[1]));
    let tracked_dest_dir = args
        .get(3)
        .map(|tracked| setup_absolute_path(&expand_home(tracked)))
        .unwrap_or_else(|| dest_dir.clone());
    println!(
        "{}",
        managed_tree_decision(state_file, &dest_dir, &args[2], &tracked_dest_dir)?
    );
    Ok(())
}

pub(crate) fn managed_tree_decision(
    state_file: &Path,
    dest_dir: &Path,
    source_prefix: &str,
    tracked_dest_dir: &Path,
) -> SetupResult<&'static str> {
    if !state_file.exists() {
        return Ok("UNOWNED:no_state");
    }
    let state = read_state(state_file)?;
    ensure_state_version(&state)?;
    managed_tree_decision_for_state(&state, dest_dir, source_prefix, tracked_dest_dir)
}

fn managed_tree_decision_for_state(
    state: &Value,
    dest_dir: &Path,
    source_prefix: &str,
    tracked_dest_dir: &Path,
) -> SetupResult<&'static str> {
    let source_prefix = source_prefix.trim_end_matches('/');
    match std::fs::symlink_metadata(dest_dir) {
        Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {}
        Ok(_) => return Ok("UNOWNED:path_type"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok("UNOWNED:missing"),
        Err(error) => return Err(error.into()),
    }

    let files = state
        .get("files")
        .and_then(Value::as_object)
        .ok_or("install-state files must be an object")?;
    let tracked = files
        .iter()
        .filter_map(|(dest, info)| {
            let expanded = setup_absolute_path(&expand_home(dest));
            let relative = expanded.strip_prefix(tracked_dest_dir).ok()?;
            Some((dest_dir.join(relative), info))
        })
        .collect::<BTreeMap<_, _>>();
    if tracked.is_empty() {
        return Ok("UNOWNED:not_tracked");
    }

    let mut leaves = BTreeSet::new();
    let mut directories = BTreeSet::new();
    collect_managed_tree_paths(dest_dir, &mut leaves, &mut directories)?;
    for leaf in &leaves {
        let Some(info) = tracked.get(leaf) else {
            return Ok("UNOWNED:untracked_path");
        };
        if info.get("type").and_then(Value::as_str) != Some("copy") {
            return Ok("UNOWNED:install_type");
        }
        let expected_source = info.get("source").and_then(Value::as_str).unwrap_or("");
        if expected_source != source_prefix
            && !expected_source.starts_with(&format!("{source_prefix}/"))
        {
            return Ok("UNOWNED:source_mismatch");
        }
        let Some(expected_checksum) = info.get("checksum").and_then(Value::as_str) else {
            return Ok("UNOWNED:missing_checksum");
        };
        let actual_checksum = format!("sha256:{}", sha256_file(leaf)?);
        if actual_checksum != expected_checksum {
            return Ok("UNOWNED:checksum_mismatch");
        }
    }
    if tracked.keys().any(|path| !leaves.contains(path)) {
        return Ok("UNOWNED:missing_tracked_path");
    }
    if directories
        .iter()
        .any(|directory| !leaves.iter().any(|leaf| leaf.starts_with(directory)))
    {
        return Ok("UNOWNED:untracked_path");
    }
    Ok("OWNED")
}

fn collect_managed_tree_paths(
    directory: &Path,
    leaves: &mut BTreeSet<PathBuf>,
    directories: &mut BTreeSet<PathBuf>,
) -> SetupResult<()> {
    for entry in std::fs::read_dir(directory)? {
        let entry = entry?;
        let path = entry.path();
        let metadata = std::fs::symlink_metadata(&path)?;
        if metadata.file_type().is_symlink() || (!metadata.is_file() && !metadata.is_dir()) {
            return Err(format!(
                "managed tree contains unsupported path type: {}",
                path.display()
            )
            .into());
        }
        if metadata.is_dir() {
            directories.insert(path.clone());
            collect_managed_tree_paths(&path, leaves, directories)?;
        } else {
            leaves.insert(path);
        }
    }
    Ok(())
}
