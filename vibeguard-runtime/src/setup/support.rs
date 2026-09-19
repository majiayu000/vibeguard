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
    let result = (|| {
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
        fs::rename(&temp, path)?;
        #[cfg(unix)]
        fs::File::open(parent)?.sync_all()?;
        Ok::<(), io::Error>(())
    })();
    if let Err(error) = result {
        if created
            && let Err(cleanup) = fs::remove_file(&temp)
            && cleanup.kind() != io::ErrorKind::NotFound
        {
            return Err(format!("{error}; temporary file cleanup failed: {cleanup}").into());
        }
        return Err(error.into());
    }
    Ok(())
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
