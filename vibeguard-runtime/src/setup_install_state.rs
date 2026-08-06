use crate::setup_quarantine_inventory::carry_incomplete_inventory;
use crate::setup_support::{
    SetupResult, home_dir, sha256_file, write_json_atomic, write_text_atomic,
};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const STATE_VERSION: i64 = 1;
const STATE_CAPABILITY_TOKEN: &str = "complete-snapshot-v1";
const INIT_USAGE: &str = "Usage: vibeguard-runtime setup-state-init <state-file> <profile> <languages> [generation] [disabled-skills] [carry-state-file] [complete-snapshot]";

pub fn capabilities(args: &[String]) -> SetupResult<()> {
    if !args.is_empty() {
        return Err("Usage: vibeguard-runtime setup-state-capabilities".into());
    }
    println!("{STATE_CAPABILITY_TOKEN}");
    Ok(())
}

pub fn init(args: &[String]) -> SetupResult<()> {
    if !(3..=7).contains(&args.len()) {
        return Err(INIT_USAGE.into());
    }
    if std::env::var_os("VIBEGUARD_TEST_SETUP_STATE_INIT_FAILURE").is_some() {
        return Err("injected setup-state initialization failure".into());
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
    let generation = args
        .get(3)
        .map(|value| value.parse::<u64>())
        .transpose()?
        .unwrap_or(1);
    let complete_snapshot = match args.get(6).map(String::as_str) {
        None => false,
        Some("complete-snapshot") => true,
        Some(_) => return Err(INIT_USAGE.into()),
    };
    if complete_snapshot {
        if !args[1].is_empty() || !args[2].is_empty() || args.get(4).is_some_and(|v| !v.is_empty())
        {
            return Err(
                "complete snapshot merge does not accept profile, languages, or disabled skills"
                    .into(),
            );
        }
        let carry_path = args.get(5).filter(|value| !value.is_empty());
        let merged = merge_complete_snapshot(state_file, carry_path.map(Path::new), generation)?;
        if std::env::var_os("VIBEGUARD_TEST_SETUP_STATE_WRITE_FAILURE").is_some() {
            return Err("injected setup-state write failure".into());
        }
        write_json_atomic(state_file, &merged)?;
        return Ok(());
    }
    if generation == 0 {
        return Err("install-state generation must be a positive integer".into());
    }
    let disabled_skills: Vec<&str> = args
        .get(4)
        .map(|value| value.split(',').filter(|name| !name.is_empty()).collect())
        .unwrap_or_default();
    let mut state = json!({
        "version": STATE_VERSION,
        "generation": generation,
        "complete": false,
        "installed_at": now_timestamp(),
        "profile": args[1],
        "languages": languages,
        "repo_dir": repo_dir,
        "files": {}
    });
    if state_file.exists() {
        let existing = read_state(state_file)?;
        validate_state_for_preflight(&existing)?;
        carry_incomplete_inventory(&existing, &mut state, generation, &disabled_skills)?;
    }
    if let Some(carry_path) = args.get(5).filter(|value| !value.is_empty()) {
        let carry = read_state(Path::new(carry_path))?;
        validate_state_for_preflight(&carry)?;
        carry_incomplete_inventory(&carry, &mut state, 0, &[])?;
    }
    if std::env::var_os("VIBEGUARD_TEST_SETUP_STATE_WRITE_FAILURE").is_some() {
        return Err("injected setup-state write failure".into());
    }
    write_json_atomic(state_file, &state)?;
    Ok(())
}

fn merge_complete_snapshot(
    state_file: &Path,
    carry_path: Option<&Path>,
    generation: u64,
) -> SetupResult<Value> {
    let mut state = read_regular_state(state_file, "complete snapshot source")?;
    validate_state_for_preflight(&state)?;
    let (complete, actual_generation) = state_generation(&state)?;
    if !complete || actual_generation != generation {
        return Err("complete snapshot source must be complete and match its generation".into());
    }
    let Some(carry_path) = carry_path else {
        return Ok(state);
    };
    if std::fs::canonicalize(state_file)? == std::fs::canonicalize(carry_path)? {
        return Err("complete snapshot carry source must be a different file".into());
    }
    let carry = read_regular_state(carry_path, "complete snapshot carry source")?;
    validate_state_for_preflight(&carry)?;
    let (carry_complete, carry_generation) = state_generation(&carry)?;
    if !carry_complete || carry_generation > generation {
        return Err("complete snapshot carry source must be a complete older generation".into());
    }
    reject_snapshot_inventory_conflicts(&state, &carry)?;
    carry_incomplete_inventory(&carry, &mut state, 0, &[])?;
    validate_state_for_preflight(&state)?;
    Ok(state)
}

fn read_regular_state(path: &Path, label: &str) -> SetupResult<Value> {
    let metadata = std::fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(format!("{label} must be a regular file").into());
    }
    read_state(path)
}

fn reject_snapshot_inventory_conflicts(current: &Value, carry: &Value) -> SetupResult<()> {
    let current_files = current["files"]
        .as_object()
        .ok_or("install-state files must be an object")?;
    let carry_files = carry["files"]
        .as_object()
        .ok_or("install-state files must be an object")?;
    let current_records = current
        .get("disabled_skill_quarantines")
        .and_then(Value::as_object);
    let carry_records = carry
        .get("disabled_skill_quarantines")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    for (carry_public, carry_record) in &carry_records {
        let public = setup_absolute_path(&expand_home(carry_public));
        if current_records.is_some_and(|records| {
            records.iter().any(|(current_public, current_record)| {
                setup_absolute_path(&expand_home(current_public)) == public
                    && (current_public != carry_public || current_record != carry_record)
            })
        }) {
            return Err("complete snapshot generations disagree on quarantine locator".into());
        }
        for (carry_path, entry) in carry_files {
            let path = setup_absolute_path(&expand_home(carry_path));
            if path != public && !path.starts_with(&public) {
                continue;
            }
            if current_files.iter().any(|(current_path, current_entry)| {
                setup_absolute_path(&expand_home(current_path)) == path
                    && (current_path != carry_path || current_entry != entry)
            }) {
                return Err("complete snapshot generations disagree on tracked inventory".into());
            }
        }
    }
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

pub fn record_project_hook(args: &[String]) -> SetupResult<()> {
    if args.len() != 4 {
        return Err(
            "Usage: vibeguard-runtime setup-state-record-project-hook <state-file> <repo-dir> <hook-path> <hook-name>"
                .into(),
        );
    }
    let state_file = Path::new(&args[0]);
    let mut state = read_state_or_empty(state_file)?;
    ensure_state_version(&state)?;
    let mut entry = serde_json::Map::new();
    entry.insert("repo_dir".to_string(), Value::String(args[1].clone()));
    entry.insert("hook_name".to_string(), Value::String(args[3].clone()));
    state
        .as_object_mut()
        .ok_or_else(|| "install-state root must be an object".to_string())?
        .entry("project_hooks")
        .or_insert_with(|| json!({}));
    state["project_hooks"]
        .as_object_mut()
        .ok_or("install-state project_hooks must be an object")?
        .insert(args[2].clone(), Value::Object(entry));
    write_json_atomic(state_file, &state)?;
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
    if let Some(languages) = state.get("languages").and_then(Value::as_array)
        && !languages.is_empty()
    {
        let text = languages
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join(", ");
        println!("Languages: {text}");
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

/// Print every tracked path at or under `dest-dir`, regardless of install type.
///
/// Managed skill copies are recorded file-by-file, so "did VibeGuard ever
/// install this skill?" is answered by whether any tracked path lives under the
/// skill directory (GH719).
pub fn list_tracked_under(args: &[String]) -> SetupResult<()> {
    if args.len() != 2 {
        return Err(
            "Usage: vibeguard-runtime setup-state-list-tracked-under <state-file> <dest-dir>"
                .into(),
        );
    }
    let state_file = Path::new(&args[0]);
    if !state_file.exists() {
        return Ok(());
    }
    let state = read_state(state_file)?;
    validate_state_for_preflight(&state)?;
    let dest_dir = setup_absolute_path(&expand_home(&args[1]));
    let files = state
        .get("files")
        .and_then(Value::as_object)
        .ok_or("install-state files must be an object")?;
    for dest in files.keys() {
        let expanded = setup_absolute_path(&expand_home(dest));
        if expanded == dest_dir || expanded.starts_with(&dest_dir) {
            println!("{}", expanded.display());
        }
    }
    Ok(())
}

pub fn generation(args: &[String]) -> SetupResult<()> {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime setup-state-generation <state-file>".into());
    }
    let state = read_state(Path::new(&args[0]))?;
    validate_state_for_preflight(&state)?;
    let (complete, generation) = state_generation(&state)?;
    println!(
        "{}\t{generation}",
        if complete { "COMPLETE" } else { "INCOMPLETE" }
    );
    Ok(())
}

pub fn mark_complete(args: &[String]) -> SetupResult<()> {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime setup-state-mark-complete <state-file>".into());
    }
    let path = Path::new(&args[0]);
    let mut state = read_state(path)?;
    validate_state_for_preflight(&state)?;
    let (_, generation) = state_generation(&state)?;
    if generation == 0 {
        return Err("legacy install-state must be prepared before completion".into());
    }
    state
        .as_object_mut()
        .ok_or("install-state root must be an object")?
        .insert("complete".into(), Value::Bool(true));
    write_json_atomic(path, &state)
}

pub fn publish_lock_owner(args: &[String]) -> SetupResult<()> {
    if args.len() != 3 && args.len() != 4 {
        return Err(
            "Usage: vibeguard-runtime setup-lock-publish-owner <lock-dir> <pid> <nonce> [reclaiming]"
                .into(),
        );
    }
    if args[1].is_empty() || args[1] == "0" || !args[1].bytes().all(|byte| byte.is_ascii_digit()) {
        return Err("setup lock pid must be a positive decimal integer".into());
    }
    if args[2].is_empty() || args[2].contains(['\n', '\r']) {
        return Err("setup lock nonce must be a non-empty single line".into());
    }
    let lock_dir = Path::new(&args[0]);
    let metadata = std::fs::symlink_metadata(lock_dir)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err("setup lock path must be a regular directory".into());
    }
    let owner_name = args.get(3).map(String::as_str).unwrap_or("owner");
    if owner_name != "owner" && owner_name != "reclaiming" {
        return Err("setup lock owner name must be owner or reclaiming".into());
    }
    let owner = lock_dir.join(owner_name);
    if owner.exists() || std::fs::symlink_metadata(&owner).is_ok() {
        return Err("setup lock owner already exists".into());
    }
    let content = format!("pid={}\nnonce={}\n", args[1], args[2]);
    if owner_name == "reclaiming" {
        remove_abandoned_reclaimer_stages(lock_dir)?;
        let staged = lock_dir.join(format!(".reclaiming.{}.{}", args[1], args[2]));
        write_text_atomic(&staged, &content)?;
        if let Err(link_error) = std::fs::hard_link(&staged, &owner) {
            std::fs::remove_file(&staged).map_err(|cleanup_error| {
                format!("{link_error}; staged reclaimer cleanup failed: {cleanup_error}")
            })?;
            return Err(link_error.into());
        }
        std::fs::remove_file(&staged)?;
    } else {
        write_text_atomic(&owner, &content)?;
    }
    #[cfg(unix)]
    if let Err(error) = std::fs::File::open(lock_dir).and_then(|file| file.sync_all()) {
        if let Err(cleanup_error) = std::fs::remove_file(&owner)
            && cleanup_error.kind() != std::io::ErrorKind::NotFound
        {
            return Err(
                format!("{error}; setup lock owner cleanup failed: {cleanup_error}").into(),
            );
        }
        return Err(error.into());
    }
    Ok(())
}

fn remove_abandoned_reclaimer_stages(lock_dir: &Path) -> SetupResult<()> {
    for entry in std::fs::read_dir(lock_dir)? {
        let path = entry?.path();
        let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
            return Err("setup lock contains a non-UTF-8 staged reclaimer".into());
        };
        if !name.starts_with(".reclaiming.") {
            continue;
        }
        let metadata = std::fs::symlink_metadata(&path)?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err("setup lock staged reclaimer is not a regular file".into());
        }
        let content = std::fs::read_to_string(&path)?;
        let mut lines = content.lines();
        let pid = lines.next().and_then(|line| line.strip_prefix("pid="));
        let nonce = lines.next().and_then(|line| line.strip_prefix("nonce="));
        if lines.next().is_some()
            || pid
                .is_none_or(|value| value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()))
            || nonce.is_none_or(str::is_empty)
            || Some(name)
                != pid
                    .zip(nonce)
                    .map(|(pid, nonce)| format!(".reclaiming.{pid}.{nonce}"))
                    .as_deref()
        {
            return Err("setup lock staged reclaimer metadata is malformed".into());
        }
        std::fs::remove_file(path)?;
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

pub fn list_project_hooks(args: &[String]) -> SetupResult<()> {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime setup-state-list-project-hooks <state-file>".into());
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
        eprintln!("WARN: unsupported install-state version; skipping project hook cleanup");
        return Ok(());
    }
    let hooks = state
        .get("project_hooks")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    for (hook_path, info) in hooks {
        let repo_dir = info.get("repo_dir").and_then(Value::as_str).unwrap_or("");
        let hook_name = info.get("hook_name").and_then(Value::as_str).unwrap_or("");
        if hook_path.is_empty() || hook_name.is_empty() {
            continue;
        }
        println!(
            "{}\t{}\t{}",
            expand_home(&hook_path).display(),
            hook_name,
            repo_dir
        );
    }
    Ok(())
}

pub(crate) fn read_state(path: &Path) -> SetupResult<Value> {
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

pub(crate) fn validate_state_for_preflight(state: &Value) -> SetupResult<()> {
    crate::setup_managed_tree_remove::validate_state_metadata(state)?;
    crate::setup_managed_tree_remove::validate_state_artifacts(state)?;
    let version = state
        .get("version")
        .and_then(Value::as_i64)
        .ok_or("install-state version must be an integer")?;
    if version != STATE_VERSION {
        return Err(format!(
            "Unsupported install-state version: {version} (expected {STATE_VERSION})"
        )
        .into());
    }
    let files = state
        .get("files")
        .and_then(Value::as_object)
        .ok_or("install-state files must be an object")?;
    for (dest, raw_entry) in files {
        if dest.is_empty() {
            return Err("install-state destination must be non-empty".into());
        }
        let entry = raw_entry
            .as_object()
            .ok_or_else(|| format!("install-state entry must be an object: {dest}"))?;
        let source = entry
            .get("source")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                format!("install-state entry source must be a non-empty string: {dest}")
            })?;
        if source.contains(['\n', '\r']) {
            return Err(format!("install-state entry source must be a single line: {dest}").into());
        }
        let install_type = entry
            .get("type")
            .and_then(Value::as_str)
            .ok_or_else(|| format!("install-state entry type must be a string: {dest}"))?;
        match install_type {
            "copy" => {
                let checksum = entry
                    .get("checksum")
                    .and_then(Value::as_str)
                    .ok_or_else(|| format!("install-state copy checksum is required: {dest}"))?;
                let digest = checksum.strip_prefix("sha256:").unwrap_or("");
                if digest.len() != 64
                    || !digest
                        .bytes()
                        .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
                {
                    return Err(format!("install-state copy checksum is invalid: {dest}").into());
                }
            }
            "symlink" => {
                if entry.contains_key("checksum") {
                    return Err(
                        format!("install-state symlink checksum must be absent: {dest}").into(),
                    );
                }
            }
            _ => return Err(format!("install-state entry type is unsupported: {dest}").into()),
        }
    }
    state_generation(state)?;
    Ok(())
}

fn state_generation(state: &Value) -> SetupResult<(bool, u64)> {
    match (state.get("generation"), state.get("complete")) {
        (None, None) => Ok((true, 0)),
        (Some(generation), Some(complete)) => {
            let generation = generation
                .as_u64()
                .filter(|value| *value > 0)
                .ok_or("install-state generation must be a positive integer")?;
            let complete = complete
                .as_bool()
                .ok_or("install-state complete must be a boolean")?;
            Ok((complete, generation))
        }
        _ => Err("install-state generation and complete must be declared together".into()),
    }
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

pub(crate) fn expand_home(path: &str) -> PathBuf {
    if let Some(stripped) = path.strip_prefix("~/")
        && let Some(home) = home_dir()
    {
        return home.join(stripped);
    }
    PathBuf::from(path)
}

pub(crate) fn setup_absolute_path(path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn unique_temp_dir(name: &str) -> SetupResult<PathBuf> {
        let mut path = std::env::temp_dir();
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        path.push(format!("vibeguard-{name}-{}-{nanos}", std::process::id()));
        fs::create_dir_all(&path)?;
        Ok(path)
    }

    #[test]
    fn record_file_stores_checksum_for_regular_files() -> SetupResult<()> {
        let dir = unique_temp_dir("install-state-record")?;
        let state_file = dir.join("install-state.json");
        let tracked = dir.join("tracked.txt");
        fs::write(&tracked, "hello")?;

        record_file(&[
            state_file.display().to_string(),
            tracked.display().to_string(),
            "generated/tracked.txt".to_string(),
            "copy".to_string(),
        ])?;

        let state = read_state(&state_file)?;
        let entry = state
            .get("files")
            .and_then(Value::as_object)
            .and_then(|files| files.get(&tracked.display().to_string()));
        assert_eq!(
            entry
                .and_then(|value| value.get("type"))
                .and_then(Value::as_str),
            Some("copy")
        );
        assert_eq!(
            entry
                .and_then(|value| value.get("checksum"))
                .and_then(Value::as_str),
            Some("sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        );

        let _ = fs::remove_dir_all(dir);
        Ok(())
    }

    #[test]
    fn record_project_hook_stores_repo_and_hook_name() -> SetupResult<()> {
        let dir = unique_temp_dir("install-state-project-hook")?;
        let state_file = dir.join("install-state.json");
        let repo_dir = dir.join("project");
        let hook_path = repo_dir.join(".git/hooks/pre-commit");
        let hook_parent = hook_path
            .parent()
            .ok_or_else(|| "hook path has no parent".to_string())?;
        fs::create_dir_all(hook_parent)?;
        fs::write(&hook_path, "hook")?;

        record_project_hook(&[
            state_file.display().to_string(),
            repo_dir.display().to_string(),
            hook_path.display().to_string(),
            "pre-commit".to_string(),
        ])?;

        let state = read_state(&state_file)?;
        let entry = state
            .get("project_hooks")
            .and_then(Value::as_object)
            .and_then(|hooks| hooks.get(&hook_path.display().to_string()));
        assert_eq!(
            entry
                .and_then(|value| value.get("repo_dir"))
                .and_then(Value::as_str),
            Some(
                repo_dir
                    .to_str()
                    .ok_or_else(|| "temp path is not utf-8".to_string())?
            )
        );
        assert_eq!(
            entry
                .and_then(|value| value.get("hook_name"))
                .and_then(Value::as_str),
            Some("pre-commit")
        );

        fs::remove_dir_all(dir)?;
        Ok(())
    }

    #[test]
    fn unsupported_state_version_is_rejected() {
        let state = json!({"version": 2, "files": {}});
        assert!(ensure_state_version(&state).is_err());
    }

    #[test]
    fn installed_timestamp_is_epoch_seconds() {
        let timestamp = now_timestamp();
        assert!(timestamp.len() >= 10);
        assert!(timestamp.chars().all(|ch| ch.is_ascii_digit()));
    }
}
