#![cfg(unix)]

use serde_json::{Value, json};
use std::ffi::OsString;
use std::fs;
use std::os::unix::ffi::OsStringExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

const BIN: &str = env!("CARGO_BIN_EXE_vibeguard-runtime");
static SEQUENCE: AtomicU64 = AtomicU64::new(0);
const USER_TEXT: &str = "User instructions\r\n";
const CORE: &str = "<!-- vibeguard-core:start -->\nold core\n<!-- vibeguard-core:end -->\n";
const LEGACY: &str = "<!-- vibeguard-start -->\nold rules\n<!-- vibeguard-end -->\n";

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "vibeguard-claude-dir-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        // current_dir resolves macOS's /var -> /private/var temporary path alias.
        Self(fs::canonicalize(path).unwrap())
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.0) {
            if std::thread::panicking() {
                eprintln!("test cleanup failed: {error}");
            } else {
                panic!("test cleanup failed: {error}");
            }
        }
    }
}

fn run(
    action: &str,
    cwd: &Path,
    home: &Path,
    override_dir: Option<&Path>,
    explicit: bool,
) -> (i32, Value) {
    let mut command = Command::new(BIN);
    command
        .args([action, "claude"])
        .current_dir(cwd)
        .env("HOME", home)
        .env_remove("CLAUDE_CONFIG_DIR")
        .env_remove("CODEX_HOME")
        .env_remove("GEMINI_CLI_HOME");
    if let Some(dir) = override_dir {
        command.env("CLAUDE_CONFIG_DIR", dir);
    }
    if explicit {
        command.arg("--home").arg(home);
    }
    let output = command.output().unwrap();
    let report = serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
        panic!(
            "{action}: {error}; stderr={}",
            String::from_utf8_lossy(&output.stderr)
        )
    });
    (output.status.code().unwrap(), report)
}

fn lifecycle(override_value: Option<&str>, explicit: bool) {
    let temp = Temp::new();
    let home = temp.0.join("home");
    let default_dir = home.join(".claude");
    let absolute_dir = temp.0.join("absolute-claude");
    let override_dir = override_value.map(|value| {
        if value == "absolute" {
            absolute_dir.clone()
        } else {
            PathBuf::from(value)
        }
    });
    let selected = if explicit {
        default_dir.clone()
    } else {
        match override_dir
            .as_ref()
            .filter(|dir| !dir.as_os_str().is_empty())
        {
            Some(dir) if dir.is_absolute() => dir.clone(),
            Some(dir) => temp.0.join(dir),
            None => default_dir.clone(),
        }
    };
    // Leave sentinels in both the default and ambient locations to detect stray writes.
    let untouched = if selected == default_dir {
        absolute_dir
    } else {
        default_dir
    };
    fs::create_dir_all(&untouched).unwrap();
    fs::write(untouched.join("settings.json"), "{\"untouched\":true}\n").unwrap();
    fs::write(
        untouched.join("CLAUDE.md"),
        format!("Untouched instructions\n{LEGACY}"),
    )
    .unwrap();
    fs::create_dir_all(&selected).unwrap();
    let config_path = selected.join("settings.json");
    let instructions_path = selected.join("CLAUDE.md");
    let user_hook =
        json!({"matcher":"Bash","hooks":[{"type":"command","command":"echo user-hook"}]});
    let initial = json!({"custom":true,"hooks":{"PreToolUse":[user_hook]}});
    fs::write(&config_path, serde_json::to_string(&initial).unwrap()).unwrap();

    for action in ["install", "status", "uninstall"] {
        // Both mutating operations must remove only the v2 owned block.
        if action != "status" {
            fs::write(&instructions_path, format!("{USER_TEXT}{CORE}{LEGACY}")).unwrap();
        }
        let (code, report) = run(action, &temp.0, &home, override_dir.as_deref(), explicit);
        assert_eq!(code, 0, "{action}: {report}");
        assert_eq!(report["config"], json!(config_path), "{action}");
        assert_eq!(
            report["legacy"]["scheduler"]["crontab"]["access"],
            "not_applicable"
        );
        assert!(
            report["legacy"]["findings"]
                .as_array()
                .unwrap()
                .iter()
                .any(|finding| {
                    finding["location"] == json!(instructions_path)
                        && finding["category"] == "markdown"
                        && finding["evidence"] == "owned"
                }),
            "{action}: {report}"
        );
        let config: Value = serde_json::from_slice(&fs::read(&config_path).unwrap()).unwrap();
        assert_eq!(config["custom"], true);
        assert!(
            config["hooks"]["PreToolUse"]
                .as_array()
                .unwrap()
                .contains(&user_hook)
        );
        assert_eq!(
            fs::read_to_string(&instructions_path).unwrap(),
            format!("{USER_TEXT}{LEGACY}")
        );
        assert_eq!(
            fs::read_to_string(untouched.join("settings.json")).unwrap(),
            "{\"untouched\":true}\n"
        );
        assert_eq!(
            fs::read_to_string(untouched.join("CLAUDE.md")).unwrap(),
            format!("Untouched instructions\n{LEGACY}")
        );
        assert!(
            !report["legacy"]["findings"]
                .as_array()
                .unwrap()
                .iter()
                .any(|finding| { finding["location"] == json!(untouched.join("CLAUDE.md")) })
        );
        if action == "status" {
            assert_eq!(report["configured"], true);
        }
    }
    let config: Value = serde_json::from_slice(&fs::read(&config_path).unwrap()).unwrap();
    assert_eq!(config["hooks"]["PreToolUse"], json!([user_hook]));
    for event in ["PostToolUse", "PostToolUseFailure"] {
        assert!(config["hooks"][event].as_array().unwrap().is_empty());
    }
    let (code, report) = run("status", &temp.0, &home, override_dir.as_deref(), explicit);
    assert_eq!(code, 1);
    assert_eq!(report["configured"], false);
}

#[test]
fn absolute_override_is_used_for_all_setup_operations() {
    lifecycle(Some("absolute"), false);
}

#[test]
fn relative_override_is_resolved_against_working_directory() {
    lifecycle(Some("relative-claude"), false);
}

#[test]
fn empty_override_uses_default_directory() {
    lifecycle(Some(""), false);
}

#[test]
fn unset_override_uses_default_directory() {
    lifecycle(None, false);
}

#[test]
fn explicit_home_ignores_ambient_override() {
    lifecycle(Some("absolute"), true);
}

#[test]
fn non_utf8_override_fails_before_mutating_setup_files() {
    let temp = Temp::new();
    let home = temp.0.join("home");
    let host_dir = temp.0.join(OsString::from_vec(b"claude-\xff".to_vec()));
    let initial = format!("{USER_TEXT}{CORE}{LEGACY}");
    // Linux permits arbitrary path bytes; APFS does not.
    #[cfg(target_os = "linux")]
    {
        fs::create_dir(&host_dir).unwrap();
        fs::write(host_dir.join("settings.json"), "{\"custom\":true}\n").unwrap();
        fs::write(host_dir.join("CLAUDE.md"), &initial).unwrap();
    }
    for action in ["install", "uninstall"] {
        let output = Command::new(BIN)
            .args([action, "claude"])
            .current_dir(&temp.0)
            .env("HOME", &home)
            .env("CLAUDE_CONFIG_DIR", &host_dir)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(2), "{action}");
        assert!(!String::from_utf8_lossy(&output.stderr).contains("panicked"));
        assert!(!home.exists(), "{action} created home state");
        #[cfg(target_os = "linux")]
        {
            assert_eq!(
                fs::read_to_string(host_dir.join("settings.json")).unwrap(),
                "{\"custom\":true}\n"
            );
            assert_eq!(
                fs::read_to_string(host_dir.join("CLAUDE.md")).unwrap(),
                initial
            );
        }
    }
    #[cfg(not(target_os = "linux"))]
    let _ = initial;
    let (code, _) = run("install", &temp.0, &home, Some(&host_dir), true);
    assert_eq!(code, 0);
}
