use crate::setup_managed_tree_remove::{now_nanos, rename_noreplace, sync_directory};
use crate::setup_support::{SetupResult, write_text_atomic};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

const ACQUIRE_USAGE: &str = "Usage: vibeguard-runtime setup-lock-acquire <lock-dir> <pid> <nonce>";
const RELEASE_USAGE: &str = "Usage: vibeguard-runtime setup-lock-release <lock-dir> <pid> <nonce>";

pub fn acquire(args: &[String]) -> SetupResult<()> {
    validate_args(args, ACQUIRE_USAGE)?;
    let lock = Path::new(&args[0]);
    let parent = lock.parent().ok_or("setup lock path has no parent")?;
    require_directory(parent, "setup lock parent")?;
    let name = lock
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .ok_or("setup lock name must be non-empty UTF-8")?;
    let claim = reserve_sibling(parent, name, "claim")?;
    let owner = claim.join("owner");
    let content = owner_content(&args[1], &args[2]);
    if let Err(error) = write_text_atomic(&owner, &content).and_then(|()| sync_io(&claim)) {
        cleanup_directory(&claim, Some(&owner))?;
        return Err(error.into());
    }
    if std::env::var_os("VIBEGUARD_TEST_SETUP_LOCK_ACQUIRE_BEFORE_RENAME").is_some() {
        return Err("injected setup lock interruption before claim rename".into());
    }
    if let Err(error) = rename_noreplace(&claim, lock) {
        cleanup_directory(&claim, Some(&owner))?;
        return Err(format!("failed to atomically acquire setup lock: {error}").into());
    }
    sync_directory(parent)?;
    println!("ACQUIRED");
    Ok(())
}

pub fn release(args: &[String]) -> SetupResult<()> {
    validate_args(args, RELEASE_USAGE)?;
    let lock = Path::new(&args[0]);
    require_directory(lock, "setup lock")?;
    let owner = lock.join("owner");
    require_regular_file(&owner, "setup lock owner")?;
    let expected = owner_content(&args[1], &args[2]);
    if fs::read_to_string(&owner)? != expected {
        return Err("setup lock owner changed before release".into());
    }
    let mut entries = fs::read_dir(lock)?;
    let only = entries.next().transpose()?.map(|entry| entry.path());
    if only.as_deref() != Some(owner.as_path()) || entries.next().transpose()?.is_some() {
        return Err("setup lock contains unexpected data before release".into());
    }
    let parent = lock.parent().ok_or("setup lock path has no parent")?;
    let name = lock
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .ok_or("setup lock name must be non-empty UTF-8")?;
    let retired = unused_sibling(parent, name, "retired")?;
    rename_noreplace(lock, &retired)
        .map_err(|error| format!("failed to atomically retire setup lock: {error}"))?;
    sync_directory(parent)?;
    if std::env::var_os("VIBEGUARD_TEST_SETUP_LOCK_RELEASE_AFTER_RENAME").is_some() {
        return Err("injected setup lock interruption after retire rename".into());
    }
    cleanup_directory(&retired, Some(&retired.join("owner")))?;
    println!("RELEASED");
    Ok(())
}

fn validate_args(args: &[String], usage: &str) -> SetupResult<()> {
    if args.len() != 3 {
        return Err(usage.into());
    }
    if args[1].is_empty() || args[1] == "0" || !args[1].bytes().all(|byte| byte.is_ascii_digit()) {
        return Err("setup lock pid must be a positive decimal integer".into());
    }
    if args[2].is_empty() || args[2].contains(['\n', '\r']) {
        return Err("setup lock nonce must be a non-empty single line".into());
    }
    Ok(())
}

fn owner_content(pid: &str, nonce: &str) -> String {
    format!("pid={pid}\nnonce={nonce}\n")
}

fn require_directory(path: &Path, label: &str) -> SetupResult<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(format!("{label} must be a regular directory").into());
    }
    Ok(())
}

fn require_regular_file(path: &Path, label: &str) -> SetupResult<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(format!("{label} must be a regular file").into());
    }
    Ok(())
}

fn reserve_sibling(parent: &Path, name: &str, phase: &str) -> SetupResult<PathBuf> {
    for attempt in 1..=10 {
        let path = sibling(parent, name, phase, attempt);
        match fs::create_dir(&path) {
            Ok(()) => return Ok(path),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
    Err(format!("failed to reserve setup lock {phase} directory").into())
}

fn unused_sibling(parent: &Path, name: &str, phase: &str) -> SetupResult<PathBuf> {
    for attempt in 1..=10 {
        let path = sibling(parent, name, phase, attempt);
        if fs::symlink_metadata(&path).is_err() {
            return Ok(path);
        }
    }
    Err(format!("failed to reserve setup lock {phase} path").into())
}

fn sibling(parent: &Path, name: &str, phase: &str, attempt: usize) -> PathBuf {
    parent.join(format!(
        ".{name}.vibeguard-{phase}.{}-{}-{attempt}",
        std::process::id(),
        now_nanos()
    ))
}

fn cleanup_directory(directory: &Path, owner: Option<&Path>) -> SetupResult<()> {
    if let Some(owner) = owner
        && let Err(error) = fs::remove_file(owner)
        && error.kind() != io::ErrorKind::NotFound
    {
        return Err(error.into());
    }
    fs::remove_dir(directory)?;
    Ok(())
}

fn sync_io(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    std::fs::File::open(path)?.sync_all()?;
    #[cfg(windows)]
    let _ = path;
    Ok(())
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
