use crate::setup_support::{SetupResult, home_dir, sha256_file, write_json_atomic};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const STATE_VERSION: i64 = 1;

pub fn init(args: &[String]) -> SetupResult<()> {
    if args.len() != 3 {
        return Err(
            "Usage: vibeguard-runtime setup-state-init <state-file> <profile> <languages>".into(),
        );
    }
    let state_file = Path::new(&args[0]);
    let repo_dir = repo_dir_from_home();
    let languages: Vec<Value> = if args[2].is_empty() {
        Vec::new()
    } else {
        args[2]
            .split(',')
            .map(|item| Value::String(item.to_string()))
            .collect()
    };
    let state = json!({
        "version": STATE_VERSION,
        "installed_at": now_timestamp(),
        "profile": args[1],
        "languages": languages,
        "repo_dir": repo_dir,
        "files": {}
    });
    write_json_atomic(state_file, &state)?;
    Ok(())
}

pub fn record_file(args: &[String]) -> SetupResult<()> {
    if args.len() != 4 {
        return Err(
            "Usage: vibeguard-runtime setup-state-record-file <state-file> <dest> <source> <type>"
                .into(),
        );
    }
    let state_file = Path::new(&args[0]);
    let mut state = read_state_or_empty(state_file)?;
    ensure_state_version(&state)?;
    let mut entry = serde_json::Map::new();
    entry.insert("source".to_string(), Value::String(args[2].clone()));
    entry.insert("type".to_string(), Value::String(args[3].clone()));
    if args[3] != "symlink" && Path::new(&args[1]).is_file() {
        entry.insert(
            "checksum".to_string(),
            Value::String(format!("sha256:{}", sha256_file(Path::new(&args[1]))?)),
        );
    }
    state
        .as_object_mut()
        .expect("state is object")
        .entry("files")
        .or_insert_with(|| json!({}));
    state["files"]
        .as_object_mut()
        .ok_or("install-state files must be an object")?
        .insert(args[1].clone(), Value::Object(entry));
    write_json_atomic(state_file, &state)?;
    Ok(())
}

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
    let files = state
        .get("files")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let mut missing_count = 0usize;
    let mut drift_count = 0usize;
    for (dest, info) in &files {
        let dest_path = expand_home(dest);
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

pub fn list(args: &[String]) -> SetupResult<()> {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime setup-state-list <state-file>".into());
    }
    let state_file = Path::new(&args[0]);
    if !state_file.exists() {
        return Err("No install state found. Run setup.sh first.".into());
    }
    let state = read_state(state_file)?;
    ensure_state_version(&state)?;
    println!(
        "Profile: {}",
        state
            .get("profile")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
    );
    println!(
        "Installed: {}",
        state
            .get("installed_at")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
    );
    if let Some(languages) = state.get("languages").and_then(Value::as_array) {
        if !languages.is_empty() {
            let text = languages
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join(", ");
            println!("Languages: {text}");
        }
    }
    let files = state
        .get("files")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    println!("Tracked files: {}", files.len());
    println!();
    for (dest, info) in files {
        let kind = info.get("type").and_then(Value::as_str).unwrap_or("?");
        println!("  [{kind:7}] {dest}");
    }
    Ok(())
}

pub fn list_tracked_symlinks_under(args: &[String]) -> SetupResult<()> {
    if args.len() != 2 {
        return Err(
            "Usage: vibeguard-runtime setup-state-list-symlinks-under <state-file> <dest-dir>"
                .into(),
        );
    }
    let state_file = Path::new(&args[0]);
    if !state_file.exists() {
        return Ok(());
    }
    let state = match read_state(state_file) {
        Ok(state) => state,
        Err(_) => return Ok(()),
    };
    if state
        .get("version")
        .and_then(Value::as_i64)
        .unwrap_or(STATE_VERSION)
        != STATE_VERSION
    {
        eprintln!("WARN: unsupported install-state version; skipping tracked symlink cleanup");
        return Ok(());
    }
    let dest_dir = setup_absolute_path(&expand_home(&args[1]));
    let files = state
        .get("files")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    for (dest, info) in files {
        if info.get("type").and_then(Value::as_str) != Some("symlink") {
            continue;
        }
        let expanded = setup_absolute_path(&expand_home(&dest));
        if expanded == dest_dir || expanded.starts_with(&dest_dir) {
            println!("{}", expanded.display());
        }
    }
    Ok(())
}

fn read_state(path: &Path) -> SetupResult<Value> {
    let text = std::fs::read_to_string(path)?;
    let value: Value = serde_json::from_str(&text)?;
    if !value.is_object() {
        return Err("install-state root must be an object".into());
    }
    Ok(value)
}

fn read_state_or_empty(path: &Path) -> SetupResult<Value> {
    if !path.exists() {
        return Ok(json!({"version": STATE_VERSION, "files": {}}));
    }
    read_state(path)
}

fn ensure_state_version(state: &Value) -> SetupResult<()> {
    let version = state
        .get("version")
        .and_then(Value::as_i64)
        .unwrap_or(STATE_VERSION);
    if version != STATE_VERSION {
        return Err(format!(
            "Unsupported install-state version: {version} (expected {STATE_VERSION})"
        )
        .into());
    }
    Ok(())
}

fn repo_dir_from_home() -> String {
    let Some(home) = home_dir() else {
        return String::new();
    };
    std::fs::read_to_string(home.join(".vibeguard/repo-path"))
        .unwrap_or_default()
        .trim()
        .to_string()
}

fn now_timestamp() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    format!("{seconds}")
}

fn expand_home(path: &str) -> PathBuf {
    if let Some(stripped) = path.strip_prefix("~/") {
        if let Some(home) = home_dir() {
            return home.join(stripped);
        }
    }
    PathBuf::from(path)
}

fn setup_absolute_path(path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    }
}
