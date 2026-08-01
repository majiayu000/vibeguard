use crate::setup_install_state::managed_tree_decision;
use crate::setup_support::{SetupResult, sha256_file};
use std::ffi::CString;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const USAGE: &str = "Usage: vibeguard-runtime setup-state-remove-managed-tree <state-file> <previous-state-file> <dest-dir> <source-prefix>";

#[derive(Clone, Debug, Eq, PartialEq)]
struct LeafSnapshot {
    path: PathBuf,
    identity: FileIdentity,
    checksum: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct FileIdentity {
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
    #[cfg(windows)]
    volume: Option<u32>,
    #[cfg(windows)]
    index: Option<u64>,
    len: u64,
}

#[derive(Debug)]
struct TreeSnapshot {
    leaves: Vec<LeafSnapshot>,
    directories: Vec<PathBuf>,
}

struct StagedLeaf {
    original: PathBuf,
    staged: PathBuf,
    snapshot: LeafSnapshot,
}

pub fn run(args: &[String]) -> SetupResult<()> {
    if args.len() != 4 {
        return Err(USAGE.into());
    }
    let states = [Path::new(&args[0]), Path::new(&args[1])];
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
    if !owned_by_any_state(&states, &dest, &args[3], &dest)? {
        return Err(format!(
            "managed tree is not an exact VibeGuard-owned copy: {}",
            dest.display()
        )
        .into());
    }

    let quarantine = quarantine_noreplace(&dest, parent, name)?;
    let transaction = remove_quarantined(&states, &dest, &quarantine, &args[3]);
    match transaction {
        Ok(()) => {
            println!("REMOVED");
            Ok(())
        }
        Err(error) => restore_or_preserve(&dest, &quarantine, error),
    }
}

fn remove_quarantined(
    states: &[&Path; 2],
    dest: &Path,
    quarantine: &Path,
    source_prefix: &str,
) -> SetupResult<()> {
    if !owned_by_any_state(states, quarantine, source_prefix, dest)? {
        return Err("quarantined tree failed ownership revalidation".into());
    }
    let snapshot = snapshot_tree(quarantine)?;
    if !owned_by_any_state(states, quarantine, source_prefix, dest)? {
        return Err("quarantined tree changed after ownership verification".into());
    }
    inject_postverify_for_test(quarantine, dest)?;
    remove_snapshot(quarantine, snapshot)
}

fn owned_by_any_state(
    states: &[&Path; 2],
    actual: &Path,
    source_prefix: &str,
    tracked: &Path,
) -> SetupResult<bool> {
    let mut owned = false;
    for state in states {
        if state.exists() {
            owned |= managed_tree_decision(state, actual, source_prefix, tracked)? == "OWNED";
        }
    }
    Ok(owned)
}

fn quarantine_noreplace(dest: &Path, parent: &Path, name: &str) -> SetupResult<PathBuf> {
    for attempt in 1..=10 {
        let candidate = parent.join(format!(
            ".{name}.vibeguard-remove.{}-{}-{attempt}",
            std::process::id(),
            now_nanos()
        ));
        inject_collision_for_test(&candidate)?;
        match rename_noreplace(dest, &candidate) {
            Ok(()) => return Ok(candidate),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(format!(
                    "failed to atomically quarantine {}: {error}",
                    dest.display()
                )
                .into());
            }
        }
    }
    Err(format!(
        "failed to reserve unique quarantine for managed tree: {}",
        dest.display()
    )
    .into())
}

fn restore_or_preserve(
    dest: &Path,
    quarantine: &Path,
    error: Box<dyn std::error::Error>,
) -> SetupResult<()> {
    match fs::symlink_metadata(quarantine) {
        Ok(_) => {}
        Err(metadata_error) if metadata_error.kind() == io::ErrorKind::NotFound => {
            return Err(error);
        }
        Err(metadata_error) => {
            return Err(format!(
                "{error}; cannot inspect quarantine before restore: {}: {metadata_error}",
                quarantine.display()
            )
            .into());
        }
    }
    inject_public_replacement_for_test(dest)?;
    match rename_noreplace(quarantine, dest) {
        Ok(()) => Err(format!("{error}; restored public tree without deletion").into()),
        Err(restore_error) if restore_error.kind() == io::ErrorKind::AlreadyExists => Err(format!(
            "{error}; public destination was replaced; quarantined data preserved at {}",
            quarantine.display()
        )
        .into()),
        Err(restore_error) => Err(format!(
            "{error}; restore failed ({restore_error}); quarantined data preserved at {}",
            quarantine.display()
        )
        .into()),
    }
}

fn snapshot_tree(root: &Path) -> SetupResult<TreeSnapshot> {
    let mut snapshot = TreeSnapshot {
        leaves: Vec::new(),
        directories: Vec::new(),
    };
    snapshot_directory(root, &mut snapshot)?;
    snapshot
        .directories
        .sort_by_key(|path| std::cmp::Reverse(path.components().count()));
    snapshot
        .leaves
        .sort_by(|left, right| left.path.cmp(&right.path));
    Ok(snapshot)
}

fn snapshot_directory(directory: &Path, snapshot: &mut TreeSnapshot) -> SetupResult<()> {
    for entry in fs::read_dir(directory)? {
        let path = entry?.path();
        let metadata = fs::symlink_metadata(&path)?;
        if metadata.file_type().is_symlink() || (!metadata.is_file() && !metadata.is_dir()) {
            return Err(format!(
                "managed tree contains unsupported path type: {}",
                path.display()
            )
            .into());
        }
        if metadata.is_dir() {
            snapshot.directories.push(path.clone());
            snapshot_directory(&path, snapshot)?;
        } else {
            snapshot.leaves.push(LeafSnapshot {
                identity: file_identity(&metadata),
                checksum: sha256_file(&path)?,
                path,
            });
        }
    }
    Ok(())
}

fn remove_snapshot(root: &Path, snapshot: TreeSnapshot) -> SetupResult<()> {
    let stage = reserve_stage(root)?;
    let mut staged = Vec::new();
    for (index, leaf) in snapshot.leaves.into_iter().enumerate() {
        let staged_path = stage.join(index.to_string());
        if let Err(error) = rename_noreplace(&leaf.path, &staged_path) {
            rollback_staged(root, &stage, &staged)?;
            return Err(format!(
                "managed leaf could not be identity-staged: {}: {error}",
                leaf.path.display()
            )
            .into());
        }
        let item = StagedLeaf {
            original: leaf.path.clone(),
            staged: staged_path,
            snapshot: leaf,
        };
        if let Err(error) = verify_staged_leaf(&item) {
            staged.push(item);
            rollback_staged(root, &stage, &staged)?;
            return Err(error);
        }
        staged.push(item);
    }
    for directory in snapshot.directories {
        if let Err(error) = fs::remove_dir(&directory) {
            rollback_staged(root, &stage, &staged)?;
            return Err(format!(
                "managed directory changed before deletion: {}: {error}",
                directory.display()
            )
            .into());
        }
    }
    if let Err(error) = fs::remove_dir(root) {
        rollback_staged(root, &stage, &staged)?;
        return Err(format!(
            "managed tree changed before final deletion: {}: {error}",
            root.display()
        )
        .into());
    }
    for item in &staged {
        verify_staged_leaf(item).map_err(|error| {
            format!(
                "private deletion stage changed; preserved without deletion at {}: {error}",
                item.staged.display()
            )
        })?;
        fs::remove_file(&item.staged).map_err(|error| {
            format!(
                "failed to delete verified managed leaf from private stage {}: {error}",
                item.staged.display()
            )
        })?;
    }
    fs::remove_dir(&stage).map_err(|error| {
        format!(
            "managed tree removed but private deletion stage must be preserved: {}: {error}",
            stage.display()
        )
        .into()
    })
}

fn reserve_stage(root: &Path) -> SetupResult<PathBuf> {
    let parent = root.parent().ok_or("quarantine has no parent")?;
    for attempt in 1..=10 {
        let stage = parent.join(format!(
            ".vibeguard-delete-stage.{}-{}-{attempt}",
            std::process::id(),
            now_nanos()
        ));
        match fs::create_dir(&stage) {
            Ok(()) => return Ok(stage),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
    Err("failed to reserve private managed-tree deletion stage".into())
}

fn verify_staged_leaf(item: &StagedLeaf) -> SetupResult<()> {
    let metadata = fs::symlink_metadata(&item.staged)?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || file_identity(&metadata) != item.snapshot.identity
        || sha256_file(&item.staged)? != item.snapshot.checksum
    {
        return Err(format!(
            "managed leaf identity changed before deletion: {}",
            item.original.display()
        )
        .into());
    }
    Ok(())
}

fn rollback_staged(root: &Path, stage: &Path, staged: &[StagedLeaf]) -> SetupResult<()> {
    fs::create_dir_all(root)?;
    for item in staged.iter().rev() {
        if let Some(parent) = item.original.parent() {
            fs::create_dir_all(parent)?;
        }
        rename_noreplace(&item.staged, &item.original).map_err(|error| {
            format!(
                "managed-tree rollback collision; data preserved at {}: {error}",
                item.staged.display()
            )
        })?;
    }
    fs::remove_dir(stage)?;
    Ok(())
}

fn file_identity(metadata: &fs::Metadata) -> FileIdentity {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        FileIdentity {
            device: metadata.dev(),
            inode: metadata.ino(),
            len: metadata.len(),
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        FileIdentity {
            volume: metadata.volume_serial_number(),
            index: metadata.file_index(),
            len: metadata.file_size(),
        }
    }
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

fn now_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

fn inject_collision_for_test(candidate: &Path) -> SetupResult<()> {
    if std::env::var_os("VIBEGUARD_TEST_REMOVE_COLLIDE_ALL").is_some() {
        fs::create_dir(candidate)?;
        fs::write(candidate.join("collision-sentinel"), "collision\n")?;
    }
    Ok(())
}

fn inject_postverify_for_test(quarantine: &Path, _dest: &Path) -> SetupResult<()> {
    if let Some(name) = std::env::var_os("VIBEGUARD_TEST_REMOVE_POSTVERIFY_INJECT") {
        let name = PathBuf::from(name);
        if name.components().count() != 1 || name.as_os_str().is_empty() {
            return Err("test injection name must be one non-empty path component".into());
        }
        fs::write(quarantine.join(name), "user-data\n")?;
    }
    Ok(())
}

fn inject_public_replacement_for_test(dest: &Path) -> SetupResult<()> {
    if let Some(value) = std::env::var_os("VIBEGUARD_TEST_REMOVE_PUBLIC_REPLACEMENT") {
        fs::create_dir(dest)?;
        fs::write(dest.join("custom.txt"), value.to_string_lossy().as_bytes())?;
    }
    Ok(())
}
