#![cfg(unix)]

use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{Value, json};

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

#[test]
fn shared_codex_instances_report_sources_and_uninstall_only_the_selected_home() {
    let temp = Temp::new();
    let first = temp.0.join("first's home");
    let second = temp.0.join("second");
    let shared = temp.0.join("shared-codex");
    fs::create_dir(&shared).unwrap();
    let user_group = json!({"matcher":"Bash","hooks":[
        {"type":"command","command":"echo third-party","timeout":17},
        {"type":"command","command":"echo vibeguard-runtime hook codex --state-dir literal"}
    ]});
    let config_path = shared.join("hooks.json");
    fs::write(
        &config_path,
        json!({
            "custom":42,"hooks":{"PreToolUse":[user_group.clone()]}
        })
        .to_string(),
    )
    .unwrap();
    // HOME selects the two fixture instances. Avoid reading the real account's
    // crontab when the advisory inventory checks that selected account home.
    let bin = temp.0.join("bin");
    fs::create_dir(&bin).unwrap();
    fs::write(bin.join("crontab"), "#!/bin/sh\nexit 0\n").unwrap();
    fs::set_permissions(bin.join("crontab"), fs::Permissions::from_mode(0o755)).unwrap();
    let path = std::env::join_paths(std::iter::once(bin).chain(std::env::split_paths(
        &std::env::var_os("PATH").unwrap_or_default(),
    )))
    .unwrap();
    let run = |home: &Path, action: &str| {
        Command::new(BIN)
            .args([action, "codex"])
            .env("HOME", home)
            .env("CODEX_HOME", &shared)
            .env("PATH", &path)
            .current_dir(&temp.0)
            .output()
            .unwrap()
    };
    for home in [&first, &second, &first] {
        let installed = run(home, "install");
        assert!(
            installed.status.success(),
            "{}",
            String::from_utf8_lossy(&installed.stderr)
        );
    }
    let before_status = fs::read(&config_path).unwrap();
    let config: Value = serde_json::from_slice(&before_status).unwrap();
    for home in [&first, &second] {
        let output = run(home, "status");
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let status: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(status["installation_home"], json!(home));
        assert_eq!(
            status["binary"],
            json!(home.join(".vibeguard/bin/vibeguard-runtime"))
        );
        assert_eq!(status["state_dir"], json!(home.join(".vibeguard/state")));
        let registrations = status["hook_registrations"].as_array().unwrap();
        assert_eq!(registrations.len(), 6);
        assert_eq!(
            registrations
                .iter()
                .filter(|entry| entry["selected_instance"] == true)
                .count(),
            2
        );
        for entry in registrations {
            let event = entry["event"].as_str().unwrap();
            let group = entry["group_index"].as_u64().unwrap() as usize;
            let hook = entry["hook_index"].as_u64().unwrap() as usize;
            assert_eq!(
                entry["command"],
                config["hooks"][event][group]["hooks"][hook]["command"]
            );
        }
        assert!(String::from_utf8_lossy(&output.stderr).contains("Additional command handlers"));
    }
    assert_eq!(
        fs::read(&config_path).unwrap(),
        before_status,
        "status must be read-only"
    );

    assert!(run(&first, "uninstall").status.success());
    let second_status = run(&second, "status");
    assert!(second_status.status.success());
    let status: Value = serde_json::from_slice(&second_status.stdout).unwrap();
    assert_eq!(status["hook_registrations"].as_array().unwrap().len(), 4);
    assert_eq!(run(&first, "status").status.code(), Some(1));
    let after_first = fs::read(&config_path).unwrap();
    assert!(run(&first, "uninstall").status.success());
    assert_eq!(fs::read(&config_path).unwrap(), after_first);

    assert!(run(&second, "uninstall").status.success());
    let final_config: Value = serde_json::from_slice(&fs::read(&config_path).unwrap()).unwrap();
    assert_eq!(final_config["custom"], 42);
    assert_eq!(final_config["hooks"]["PreToolUse"], json!([user_group]));
    assert_eq!(final_config["hooks"]["PostToolUse"], json!([]));
    for home in [&first, &second] {
        assert!(home.join(".vibeguard/bin/vibeguard-runtime").is_file());
        assert_eq!(run(home, "status").status.code(), Some(1));
    }
}
