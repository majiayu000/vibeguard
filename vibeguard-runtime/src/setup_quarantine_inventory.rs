use crate::setup_install_state::{expand_home, read_state, setup_absolute_path};
use crate::setup_managed_tree_remove::validate_state_metadata;
use crate::setup_support::{SetupResult, sha256_file};
use serde_json::Value;
use std::path::{Path, PathBuf};

const USAGE: &str = "Usage: vibeguard-runtime setup-state-quarantine-count <state-file>";
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
    if args.len() != 1 {
        return Err(USAGE.into());
    }
    let state_path = Path::new(&args[0]);
    if !state_path.exists() {
        println!("0");
        return Ok(());
    }
    let state = read_state(state_path)?;
    validate_state_metadata(&state)?;
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

pub(crate) fn carry_incomplete_inventory(
    existing: &Value,
    target: &mut Value,
    generation: u64,
) -> SetupResult<()> {
    validate_state_metadata(existing)?;
    if existing.get("complete").and_then(Value::as_bool) != Some(false)
        || existing.get("generation").and_then(Value::as_u64) != Some(generation)
    {
        return Ok(());
    }
    let Some(records) = existing
        .get("disabled_skill_quarantines")
        .and_then(Value::as_object)
    else {
        return Ok(());
    };
    let source_files = existing
        .get("files")
        .and_then(Value::as_object)
        .ok_or("install-state files must be an object")?;
    let target_object = target
        .as_object_mut()
        .ok_or("install-state root must be an object")?;
    target_object.insert(
        "disabled_skill_quarantines".into(),
        Value::Object(records.clone()),
    );
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
    Ok(())
}
