//! Locked JSONL persistence shared by hook and observability producers.

use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

pub(crate) fn append_jsonl(path: &Path, line: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let existed = path.exists();
    let _lock = JsonlAppendLock::acquire(path)?;
    if existed {
        set_owner_only(path);
    }
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file = options.open(path)?;
    let mut entry = String::with_capacity(line.len() + 1);
    entry.push_str(line);
    entry.push('\n');
    file.write_all(entry.as_bytes())?;
    set_owner_only(path);
    Ok(())
}

pub(crate) fn append_jsonl_mirror(primary: &Path, mirror: &Path, line: &str) -> io::Result<()> {
    let primary_result = append_jsonl(primary, line).map_err(|err| {
        io::Error::new(
            err.kind(),
            format!(
                "primary JSONL append failed for {}: {err}",
                primary.display()
            ),
        )
    });
    let mirror_result = if mirror == primary {
        Ok(())
    } else {
        append_jsonl(mirror, line).map_err(|err| {
            io::Error::new(
                err.kind(),
                format!("mirror JSONL append failed for {}: {err}", mirror.display()),
            )
        })
    };

    match (primary_result, mirror_result) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(primary_err), Ok(())) => Err(primary_err),
        (Ok(()), Err(mirror_err)) => Err(mirror_err),
        (Err(primary_err), Err(mirror_err)) => {
            let kind = primary_err.kind();
            Err(io::Error::new(kind, format!("{primary_err}; {mirror_err}")))
        }
    }
}

struct JsonlAppendLock {
    lock_dir: PathBuf,
}

impl JsonlAppendLock {
    fn acquire(path: &Path) -> io::Result<Self> {
        let mut lock_dir = path.as_os_str().to_os_string();
        lock_dir.push(".lock.d");
        let lock_dir = PathBuf::from(lock_dir);
        let max_attempts = jsonl_lock_attempts();
        let sleep_duration = jsonl_lock_sleep_duration();

        for attempt in 0..max_attempts {
            match fs::create_dir(&lock_dir) {
                Ok(()) => return Ok(Self { lock_dir }),
                Err(err) if err.kind() == io::ErrorKind::AlreadyExists => {
                    if remove_stale_jsonl_lock(&lock_dir)? {
                        match fs::create_dir(&lock_dir) {
                            Ok(()) => return Ok(Self { lock_dir }),
                            Err(err) if err.kind() == io::ErrorKind::AlreadyExists => {}
                            Err(err) => return Err(err),
                        }
                    }
                    if attempt + 1 < max_attempts && !sleep_duration.is_zero() {
                        std::thread::sleep(sleep_duration);
                    }
                }
                Err(err) => return Err(err),
            }
        }

        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            format!(
                "timed out waiting for JSONL append lock after {max_attempts} attempts: {}; recovery: if no VibeGuard process is active, remove this stale lock directory",
                lock_dir.display()
            ),
        ))
    }
}

fn remove_stale_jsonl_lock(lock_dir: &Path) -> io::Result<bool> {
    let stale_after = jsonl_lock_stale_duration();
    let Ok(metadata) = fs::metadata(lock_dir) else {
        return Ok(false);
    };
    if !metadata.is_dir() {
        return Ok(false);
    }
    if stale_after.is_zero() {
        return remove_jsonl_lock_dir(lock_dir);
    }
    let Ok(modified) = metadata.modified() else {
        return Ok(false);
    };
    let Ok(age) = SystemTime::now().duration_since(modified) else {
        return Ok(false);
    };
    if age < stale_after {
        return Ok(false);
    }

    remove_jsonl_lock_dir(lock_dir)
}

fn remove_jsonl_lock_dir(lock_dir: &Path) -> io::Result<bool> {
    match fs::remove_dir(lock_dir) {
        Ok(()) => Ok(true),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(true),
        Err(err) if err.kind() == io::ErrorKind::DirectoryNotEmpty => Ok(false),
        Err(err) => Err(err),
    }
}

fn jsonl_lock_attempts() -> usize {
    env::var("VIBEGUARD_LOG_LOCK_ATTEMPTS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .map(|value| value.max(1))
        .unwrap_or(100)
}

fn jsonl_lock_sleep_duration() -> Duration {
    env::var("VIBEGUARD_LOG_LOCK_SLEEP_SECONDS")
        .ok()
        .and_then(|value| value.parse::<f64>().ok())
        .filter(|value| value.is_finite() && *value >= 0.0)
        .map(Duration::from_secs_f64)
        .unwrap_or_else(|| Duration::from_millis(10))
}

fn jsonl_lock_stale_duration() -> Duration {
    env::var("VIBEGUARD_LOG_LOCK_STALE_SECONDS")
        .ok()
        .and_then(|value| value.parse::<f64>().ok())
        .filter(|value| value.is_finite() && *value >= 0.0)
        .map(Duration::from_secs_f64)
        .unwrap_or_else(|| Duration::from_secs(10 * 60))
}

impl Drop for JsonlAppendLock {
    fn drop(&mut self) {
        let _ = fs::remove_dir(&self.lock_dir);
    }
}

#[cfg(unix)]
fn set_owner_only(path: &Path) {
    if let Ok(metadata) = fs::metadata(path) {
        let mut permissions = metadata.permissions();
        permissions.set_mode(0o600);
        let _ = fs::set_permissions(path, permissions);
    }
}

#[cfg(not(unix))]
fn set_owner_only(_path: &Path) {}

#[cfg(test)]
mod tests {
    use super::append_jsonl;
    use serde_json::Value;
    use std::fs;
    use std::path::PathBuf;

    #[test]
    fn append_jsonl_keeps_concurrent_records_parseable() {
        let temp_dir = std::env::temp_dir().join(format!(
            "vibeguard-jsonl-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let log_file = temp_dir.join("events.jsonl");
        let mut handles = Vec::new();

        for worker in 0..8 {
            let log_file = log_file.clone();
            handles.push(std::thread::spawn(move || {
                for item in 0..50 {
                    let line = serde_json::json!({
                        "worker": worker,
                        "item": item,
                    })
                    .to_string();
                    append_jsonl(&log_file, &line).unwrap();
                }
            }));
        }

        for handle in handles {
            handle.join().unwrap();
        }

        let content = fs::read_to_string(&log_file).unwrap();
        let lines: Vec<&str> = content.lines().collect();
        assert_eq!(lines.len(), 400);
        for line in lines {
            serde_json::from_str::<Value>(line).unwrap();
        }
        assert!(!PathBuf::from(format!("{}.lock.d", log_file.display())).exists());

        let _ = fs::remove_dir_all(temp_dir);
    }
}
