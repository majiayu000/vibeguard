use crate::setup_install_state::{
    expand_home, read_state, setup_absolute_path, validate_state_for_preflight,
    validate_state_for_preflight_with_released_inventory,
};
use crate::setup_managed_tree_remove::{
    tree_state::{intent_quarantine_for_dest, orphan_intent_records},
    validate_state_artifacts, validate_state_metadata,
};
use crate::setup_support::{SetupResult, sha256_file};
use serde_json::Value;
use std::path::{Path, PathBuf};

const USAGE: &str = "Usage: vibeguard-runtime setup-state-quarantine-count <state-file> [released-inventory-state-file]";
const STATE_VERSION: i64 = 1;

pub fn check_drift(args: &[String]) -> SetupResult<()> {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime setup-state-check-drift <state-file>".into());
    }
    let state_file = Path::new(&args[0]);
    if !state_file.exists() {
        println!("NO_STATE");
        return Ok(());
    }
    let state = read_state(state_file)?;
    let version = state
        .get("version")
        .and_then(Value::as_i64)
        .unwrap_or(STATE_VERSION);
    if version != STATE_VERSION {
        println!("UNSUPPORTED_STATE_VERSION: {version} (expected {STATE_VERSION})");
        return Ok(());
    }
    validate_state_metadata(&state)?;
    validate_state_artifacts(&state)?;
    let files = state
        .get("files")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let mut missing_count = 0usize;
    let mut drift_count = 0usize;
    for (dest, info) in &files {
        let dest_path = tracked_path(&state, &expand_home(dest))?;
        let install_type = info.get("type").and_then(Value::as_str).unwrap_or("");
        if install_type == "symlink" {
            match std::fs::symlink_metadata(&dest_path) {
                Ok(meta) if meta.file_type().is_symlink() => {}
                Ok(_) => {
                    println!("DRIFT: {dest} (was symlink, now regular file)");
                    drift_count += 1;
                }
                Err(_) => {
                    println!("MISSING: {dest}");
                    missing_count += 1;
                }
            }
        } else if !dest_path.exists() {
            println!("MISSING: {dest}");
            missing_count += 1;
        } else if let Some(expected) = info.get("checksum").and_then(Value::as_str) {
            let actual = format!("sha256:{}", sha256_file(&dest_path)?);
            if actual != expected {
                println!("DRIFT: {dest} (checksum mismatch)");
                drift_count += 1;
            }
        }
    }
    println!("---");
    println!(
        "Total tracked: {}, Missing: {missing_count}, Drifted: {drift_count}",
        files.len()
    );
    if missing_count + drift_count == 0 {
        println!("STATUS: CLEAN");
    } else {
        println!("STATUS: DRIFT ({drift_count} drifted, {missing_count} missing)");
    }
    Ok(())
}

pub fn count(args: &[String]) -> SetupResult<()> {
    if !(1..=2).contains(&args.len()) {
        return Err(USAGE.into());
    }
    let state_path = Path::new(&args[0]);
    if !state_path.exists() {
        println!("0");
        return Ok(());
    }
    let state = read_state(state_path)?;
    if let Some(inventory_path) = args.get(1).map(Path::new).filter(|path| path.exists()) {
        let inventory = read_state(inventory_path)?;
        validate_state_for_preflight(&inventory)?;
        validate_state_for_preflight_with_released_inventory(&state, &inventory)?;
    } else {
        validate_state_for_preflight(&state)?;
    }
    let count = state
        .get("disabled_skill_quarantines")
        .and_then(Value::as_object)
        .map_or(0, serde_json::Map::len);
    println!("{count}");
    Ok(())
}

fn tracked_path(state: &Value, dest: &Path) -> SetupResult<PathBuf> {
    let dest = setup_absolute_path(dest);
    let mut selected: Option<(usize, PathBuf)> = None;
    let Some(records) = state
        .get("disabled_skill_quarantines")
        .and_then(Value::as_object)
    else {
        return Ok(dest);
    };
    for (public, record) in records {
        let public = setup_absolute_path(&expand_home(public));
        if dest != public && !dest.starts_with(&public) {
            continue;
        }
        if quarantine_record_phase(record)? == "released" {
            continue;
        }
        let quarantine = record
            .get("quarantine")
            .and_then(Value::as_str)
            .ok_or("quarantine locator must be a string")?;
        let suffix = dest
            .strip_prefix(&public)
            .map_err(|_| "tracked quarantine path is outside its public root")?;
        let depth = public.components().count();
        let candidate = Path::new(quarantine).join(suffix);
        if selected
            .as_ref()
            .is_none_or(|(selected_depth, _)| depth > *selected_depth)
        {
            selected = Some((depth, candidate));
        }
    }
    Ok(selected.map_or(dest, |(_, path)| path))
}

fn quarantine_record_phase(record: &Value) -> SetupResult<String> {
    let transaction = record
        .get("transaction")
        .and_then(Value::as_str)
        .ok_or("quarantine locator must name a transaction")?;
    let value: Value = serde_json::from_slice(&std::fs::read(transaction)?)?;
    value
        .get("phase")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| "managed-tree transaction phase must be a string".into())
}

pub(crate) fn carry_incomplete_inventory(
    existing: &Value,
    target: &mut Value,
    generation: u64,
    disabled_skills: &[&str],
) -> SetupResult<()> {
    validate_state_metadata(existing)?;
    // Resuming an interrupted generation additionally re-carries the tracked
    // copies of every disabled skill. Active quarantine records, however, must
    // be carried unconditionally: when a disabled skill is removed or renamed
    // in a later manifest the install loop never visits its old name, so
    // nothing else republishes the locator and ownership of the retained hidden
    // tree would be lost for good on the following install.
    let resume = existing.get("complete").and_then(Value::as_bool) == Some(false)
        && existing.get("generation").and_then(Value::as_u64) == Some(generation);
    let mut records = existing
        .get("disabled_skill_quarantines")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    for (public, record) in orphan_intent_records(existing)? {
        if records
            .insert(public, record.clone())
            .is_some_and(|previous| previous != record)
        {
            return Err("install-state conflicts with durable quarantine intent".into());
        }
    }
    if records.is_empty() && !resume {
        return Ok(());
    }
    let source_files = existing
        .get("files")
        .and_then(Value::as_object)
        .ok_or("install-state files must be an object")?;
    let target_object = target
        .as_object_mut()
        .ok_or("install-state root must be an object")?;
    let target_records = target_object
        .entry("disabled_skill_quarantines")
        .or_insert_with(|| Value::Object(Default::default()))
        .as_object_mut()
        .ok_or("disabled_skill_quarantines must be an object")?;
    for (public, record) in &records {
        if target_records
            .insert(public.clone(), record.clone())
            .is_some_and(|previous| previous != *record)
        {
            return Err("install-state generations disagree on quarantine locator".into());
        }
    }
    if target_records.is_empty() {
        target_object.remove("disabled_skill_quarantines");
    }
    let target_files = target_object["files"]
        .as_object_mut()
        .ok_or("install-state files must be an object")?;
    for public in records.keys() {
        let public = setup_absolute_path(&expand_home(public));
        let mut carried = false;
        for (path, entry) in source_files {
            let path_root = setup_absolute_path(&expand_home(path));
            if path_root != public && !path_root.starts_with(&public) {
                continue;
            }
            target_files.insert(path.clone(), entry.clone());
            carried = true;
        }
        if !carried {
            return Err("active quarantine has no tracked file inventory".into());
        }
    }
    if !resume {
        return Ok(());
    }
    let Some(home) = crate::setup_support::home_dir() else {
        return Ok(());
    };
    for name in disabled_skills {
        if !valid_skill_name(name) {
            return Err("disabled skill name is invalid".into());
        }
        let public = home.join(".codex/skills").join(name);
        let actual = if public.exists() {
            public.clone()
        } else if let Some(quarantine) = intent_quarantine_for_dest(&public)? {
            quarantine
        } else {
            public.clone()
        };
        for (path, entry) in source_files {
            let path_root = setup_absolute_path(&expand_home(path));
            if path_root != public && !path_root.starts_with(&public) {
                continue;
            }
            let actual_path = actual.join(path_root.strip_prefix(&public)?);
            if tracked_copy_matches(&actual_path, entry)? {
                target_files.insert(path.clone(), entry.clone());
            }
        }
    }
    Ok(())
}

fn tracked_copy_matches(path: &Path, entry: &Value) -> SetupResult<bool> {
    if entry.get("type").and_then(Value::as_str) != Some("copy") {
        return Ok(false);
    }
    let Some(expected) = entry.get("checksum").and_then(Value::as_str) else {
        return Ok(false);
    };
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error.into()),
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Ok(false);
    }
    Ok(format!("sha256:{}", sha256_file(path)?) == expected)
}

fn valid_skill_name(name: &str) -> bool {
    !name.is_empty()
        && name.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_alphanumeric() || (index > 0 && matches!(byte, b'.' | b'_' | b'-'))
        })
}
