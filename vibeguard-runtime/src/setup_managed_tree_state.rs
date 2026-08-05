use crate::setup_install_state::{expand_home, read_state, setup_absolute_path};
use crate::setup_support::SetupResult;
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

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
    if object.get("dest").and_then(Value::as_str) != Some(dest) {
        return Err(format!(
            "active quarantine transaction names another destination: {}",
            transaction_path.display()
        )
        .into());
    }
    if object.get("phase").and_then(Value::as_str).is_none() {
        return Err(format!(
            "active quarantine transaction has no phase: {}",
            transaction_path.display()
        )
        .into());
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
    Ok(())
}
