use crate::Result;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[path = "metadata.rs"]
mod metadata;

static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

pub fn read_optional(path: &Path) -> Result<Option<Vec<u8>>> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.is_file() || metadata.file_type().is_symlink() => {
            Err(format!("{} must be a regular file, not a symlink", path.display()).into())
        }
        Ok(_) => Ok(Some(fs::read(path)?)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

pub fn read_text(path: &Path) -> Result<Option<String>> {
    read_optional(path)?
        .map(|bytes| {
            String::from_utf8(bytes).map_err(|_| format!("{} is not UTF-8", path.display()).into())
        })
        .transpose()
}

pub fn write_atomic(path: &Path, content: &[u8], new_mode: u32) -> Result<()> {
    write_atomic_inner(path, content, new_mode, None)
}

pub fn check_unchanged(path: &Path, expected: Option<&[u8]>) -> Result<()> {
    if read_optional(path)?.as_deref() != expected {
        return Err(format!(
            "{} changed during setup; retry after other configuration edits finish. Earlier setup writes may already have completed",
            path.display()
        ).into());
    }
    Ok(())
}

pub fn write_atomic_if_unchanged(
    path: &Path,
    content: &[u8],
    new_mode: u32,
    expected: Option<&[u8]>,
) -> Result<()> {
    write_atomic_inner(path, content, new_mode, Some(expected))
}

fn write_atomic_inner(
    path: &Path,
    content: &[u8],
    new_mode: u32,
    expected: Option<Option<&[u8]>>,
) -> Result<()> {
    if let Some(expected) = expected {
        check_unchanged(path, expected)?;
    }
    let original = match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            return Err(format!("{} must be a regular file", path.display()).into());
        }
        Ok(_) => Some(fs::File::open(path)?),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(error.into()),
    };
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::create_dir_all(parent)?;
    let temp = temporary_path(path);
    let mut created = false;
    let result: Result<()> = (|| {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(new_mode);
        }
        #[cfg(not(unix))]
        let _ = new_mode;
        let mut file = options.open(&temp)?;
        created = true;
        file.write_all(content)?;
        if let Some(original) = &original {
            #[cfg(any(target_os = "macos", target_os = "linux"))]
            metadata::copy(original, &file).map_err(|error| {
                io::Error::new(
                    error.kind(),
                    format!(
                        "could not preserve metadata for {}: {error}",
                        path.display()
                    ),
                )
            })?;
            #[cfg(not(any(target_os = "macos", target_os = "linux")))]
            file.set_permissions(original.metadata()?.permissions())?;
        }
        file.sync_all()?;
        drop(file);
        // Recheck after staging and metadata copies, as close to rename as possible.
        // This detects conflicts; it cannot atomically coordinate an external writer.
        if let Some(expected) = expected {
            check_unchanged(path, expected)?;
        }
        fs::rename(&temp, path)?;
        #[cfg(unix)]
        fs::File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if let Err(error) = result {
        if created
            && let Err(cleanup) = fs::remove_file(&temp)
            && cleanup.kind() != io::ErrorKind::NotFound
        {
            return Err(format!("{error}; temporary file cleanup failed: {cleanup}").into());
        }
        return Err(error);
    }
    Ok(())
}

pub fn lock_setup(home: &Path, resource_dir: &Path) -> Result<Vec<fs::File>> {
    let mut held = Vec::new();
    for path in [
        home.join(".vibeguard/setup.lock"),
        resource_dir.join(".vibeguard-setup.lock"),
    ] {
        match fs::symlink_metadata(&path) {
            Ok(metadata) if !metadata.is_file() || metadata.file_type().is_symlink() => {
                return Err(format!("{} must be a regular setup lock file", path.display()).into());
            }
            Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error.into()),
            _ => {}
        }
        fs::create_dir_all(path.parent().expect("setup lock has a parent"))?;
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let file = options.open(&path)?;
        if !file.metadata()?.is_file() {
            return Err(format!("{} must be a regular setup lock file", path.display()).into());
        }
        file.try_lock().map_err(|error| {
            format!(
                "cannot acquire setup lock {}: {error}; another VibeGuard setup may be running, retry after it finishes",
                path.display()
            )
        })?;
        held.push(file);
    }
    // Leave lock files in place: unlinking would allow two processes to lock
    // different inodes for the same resource. Closing the descriptors releases them.
    Ok(held)
}

fn temporary_path(path: &Path) -> PathBuf {
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    path.with_file_name(format!(
        ".{name}.{}-{}.tmp",
        std::process::id(),
        TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ))
}

pub fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub fn executable(path: &Path) -> Result<bool> {
    if read_optional(path)?.is_none() {
        return Ok(false);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        // The installer requires all three execute bits. This is a local mode
        // check, not proof against ACLs or a noexec mount.
        Ok(fs::metadata(path)?.permissions().mode() & 0o111 == 0o111)
    }
    #[cfg(not(unix))]
    Ok(false)
}

pub fn make_executable(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = fs::metadata(path)?.permissions().mode();
        fs::set_permissions(path, fs::Permissions::from_mode(mode | 0o111))?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "vibeguard-setup-support-{}-{}",
                std::process::id(),
                TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }

    #[test]
    fn changed_created_and_removed_user_files_are_conflicts() {
        let temp = Temp::new();
        let path = temp.0.join("settings.json");
        for (expected, latest) in [
            (Some(b"old".as_slice()), Some(b"user edit".as_slice())),
            (None, Some(b"new user file".as_slice())),
            (Some(b"old".as_slice()), None),
        ] {
            if let Some(latest) = latest {
                fs::write(&path, latest).unwrap();
                fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
            } else if path.exists() {
                fs::remove_file(&path).unwrap();
            }
            let error = write_atomic_if_unchanged(&path, b"stale replacement", 0o600, expected)
                .unwrap_err();
            assert!(error.to_string().contains("changed during setup"));
            assert_eq!(read_optional(&path).unwrap().as_deref(), latest);
            if latest.is_some() {
                assert_eq!(
                    fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                    0o640
                );
            }
            assert!(fs::read_dir(&temp.0).unwrap().all(|entry| {
                !entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .ends_with(".tmp")
            }));
        }
    }

    #[test]
    fn unchanged_snapshot_can_be_replaced_without_changing_its_mode() {
        let temp = Temp::new();
        let path = temp.0.join("settings.json");
        fs::write(&path, b"old").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        write_atomic_if_unchanged(&path, b"new", 0o600, Some(b"old")).unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"new");
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o640
        );
    }
}
