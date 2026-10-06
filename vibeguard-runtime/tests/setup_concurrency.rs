#![cfg(unix)]

use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

const BIN: &str = env!("CARGO_BIN_EXE_vibeguard-runtime");
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "vibeguard-setup-concurrency-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
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

fn invoke(home: &Path, action: &str) -> Output {
    Command::new(BIN)
        .args([action, "claude", "--home"])
        .arg(home)
        .output()
        .unwrap()
}

struct HeldLock(File);
impl Drop for HeldLock {
    fn drop(&mut self) {
        // Another test's fork can briefly inherit this descriptor before exec
        // closes it. Release the shared lock explicitly instead of waiting for
        // the last inherited descriptor to close.
        self.0.unlock().unwrap();
    }
}

fn hold(path: &Path, context: &str) -> HeldLock {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .unwrap();
    file.try_lock()
        .unwrap_or_else(|error| panic!("{context}: cannot lock {}: {error}", path.display()));
    HeldLock(file)
}

fn assert_busy(output: Output) {
    assert_eq!(output.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("another VibeGuard setup may be running"),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn competing_setups_fail_without_mutating_configuration_and_status_stays_read_only() {
    let temp = Temp::new();
    let lock_path = temp.0.join(".vibeguard/setup.lock");
    let lock = hold(&lock_path, "before initial installation");
    assert_busy(invoke(&temp.0, "install"));
    assert!(!temp.0.join(".claude/settings.json").exists());
    assert!(!temp.0.join(".vibeguard/bin/vibeguard-runtime").exists());
    drop(lock);

    let installed = invoke(&temp.0, "install");
    assert!(
        installed.status.success(),
        "{}",
        String::from_utf8_lossy(&installed.stderr)
    );
    let config = temp.0.join(".claude/settings.json");
    let before = fs::read(&config).unwrap();
    let lock = hold(&lock_path, "after installation completed");
    assert!(invoke(&temp.0, "status").status.success());
    assert_busy(invoke(&temp.0, "uninstall"));
    assert_eq!(fs::read(&config).unwrap(), before);
    drop(lock);
    assert!(invoke(&temp.0, "uninstall").status.success());
    assert!(lock_path.is_file());
    // Persistent lock files do not constitute an active lock after process exit.
    drop(hold(&lock_path, "after uninstall completed"));
}

#[test]
fn shared_codex_directory_is_locked_across_different_homes() {
    let temp = Temp::new();
    let first = temp.0.join("first");
    let second = temp.0.join("second");
    let shared = temp.0.join("shared-codex");
    let run = |home: &Path| {
        Command::new(BIN)
            .args(["install", "codex"])
            .env("HOME", home)
            .env("CODEX_HOME", &shared)
            .output()
            .unwrap()
    };
    let installed = run(&first);
    assert!(
        installed.status.success(),
        "{}",
        String::from_utf8_lossy(&installed.stderr)
    );
    let before = fs::read(shared.join("hooks.json")).unwrap();
    let lock_path = shared.join(".vibeguard-setup.lock");
    let lock = hold(&lock_path, "after installing the first shared Codex home");
    assert_busy(run(&second));
    assert_eq!(fs::read(shared.join("hooks.json")).unwrap(), before);
    assert!(!second.join(".vibeguard/bin/vibeguard-runtime").exists());
    drop(lock);
    drop(hold(
        &lock_path,
        "after releasing the shared Codex fixture lock",
    ));
}
