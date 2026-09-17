use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

const BIN: &str = env!("CARGO_BIN_EXE_vibeguard-runtime");
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "vibeguard-v2-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
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
fn invoke(args: &[&str], input: &str, cwd: Option<&Path>) -> Output {
    let mut command = Command::new(BIN);
    command
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(cwd) = cwd {
        command.current_dir(cwd);
    }
    let mut child = command.spawn().unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}
fn success(output: &Output) {
    assert!(
        output.status.success(),
        "stdout={}\nstderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
fn payload(event: &str, command: &str) -> Value {
    json!({"hook_event_name":event,"tool_name":"Bash","tool_input":{"command":command},"cwd":"/test/repo","tool_use_id":"test-call"})
}
fn native(output: &Output) -> Value {
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn standalone_catalog_and_removed_commands() {
    let output = invoke(&["rules", "--json"], "", None);
    success(&output);
    let rules = native(&output);
    assert!(
        rules
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["id"] == "TS-02"
                && r["body"].as_str().unwrap().contains("Returning a Promise"))
    );
    success(&invoke(&["rules", "rust"], "", None));
    for old in ["RS-06", "RS-14", "W-16", "TASTE-ANSI", "NO-SUCH-RULE"] {
        assert_eq!(invoke(&["rules", old], "", None).status.code(), Some(2));
    }
    for command in ["scan", "codex-app-server", "pkg-rewrite"] {
        assert_eq!(invoke(&[command], "", None).status.code(), Some(2));
    }
}

#[test]
fn native_hook_protocol_and_no_command_rewrites() {
    for host in ["claude", "codex"] {
        let denied = invoke(
            &["hook", host],
            &payload("PreToolUse", "rm -rf /").to_string(),
            None,
        );
        success(&denied);
        assert_eq!(
            native(&denied)["hookSpecificOutput"]["permissionDecision"],
            "deny"
        );
        for command in [
            "npm install",
            "pip install requests",
            "cat > docs/design.md",
            "echo cargo test",
        ] {
            let allowed = invoke(
                &["hook", host],
                &payload("PreToolUse", command).to_string(),
                None,
            );
            success(&allowed);
            assert!(allowed.stdout.is_empty());
        }
    }
}

#[test]
fn malformed_input_fails_without_leaking_payload() {
    for input in [
        "",
        "PRIVATE_SENTINEL",
        "{\"password\":\"PRIVATE_SENTINEL\",",
        "[]",
        "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"/repo\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":42}}",
    ] {
        let output = invoke(&["hook", "codex"], input, None);
        assert_eq!(output.status.code(), Some(2));
        assert!(!String::from_utf8_lossy(&output.stdout).contains("PRIVATE_SENTINEL"));
        assert!(!String::from_utf8_lossy(&output.stderr).contains("PRIVATE_SENTINEL"));
    }
}

#[test]
fn observations_record_only_reported_outcomes_and_never_raw_commands() {
    let temp = Temp::new();
    let path = temp.0.to_str().unwrap();
    for (response, outcome) in [
        (
            json!({"exit_code":0,"stdout":"PRIVATE_SENTINEL"}),
            "exited_zero",
        ),
        (json!({"exit_code":7}), "exited_nonzero"),
        (json!({"session_id":22}), "running"),
        (json!({"interrupted":true}), "interrupted"),
        (
            json!({"stdout":"cargo test passed"}),
            "exit_status_unavailable",
        ),
    ] {
        let mut event = payload("PostToolUse", "echo PRIVATE_SENTINEL cargo test");
        event["tool_response"] = response;
        success(&invoke(
            &["hook", "codex", "--state-dir", path],
            &event.to_string(),
            None,
        ));
        let text = fs::read_to_string(temp.0.join("codex.json")).unwrap();
        assert!(!text.contains("PRIVATE_SENTINEL"));
        let record: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(record["outcome"], outcome);
        assert!(record.get("verified").is_none());
    }
    success(&invoke(
        &["hook", "codex", "--state-dir", path],
        &payload("PreToolUse", "cargo test").to_string(),
        None,
    ));
    let record: Value =
        serde_json::from_slice(&fs::read(temp.0.join("codex.json")).unwrap()).unwrap();
    assert_eq!(record["outcome"], "requested");
    let mut failure = payload("PostToolUseFailure", "cargo test");
    failure["error"] = json!("Exit code 1\nPRIVATE_SENTINEL");
    success(&invoke(
        &["hook", "claude", "--state-dir", path],
        &failure.to_string(),
        None,
    ));
    assert_eq!(
        invoke(&["hook", "codex"], &failure.to_string(), None)
            .status
            .code(),
        Some(2)
    );
}

#[cfg(unix)]
#[test]
fn install_execute_and_uninstall_preserve_user_content() {
    for host in ["claude", "codex"] {
        let temp = Temp::new();
        let home = temp.0.join("developer's home $(touch SHOULD_NOT_EXIST)");
        let host_dir = home.join(format!(".{host}"));
        fs::create_dir_all(&host_dir).unwrap();
        let config_path = host_dir.join(if host == "codex" {
            "hooks.json"
        } else {
            "settings.json"
        });
        let instructions = host_dir.join(if host == "codex" {
            "AGENTS.md"
        } else {
            "CLAUDE.md"
        });
        let user_hook = json!({"matcher":"Bash","hooks":[{"type":"command","command":"echo user-hook","timeout":17}]});
        let original_config =
            json!({"custom":{"value":42},"hooks":{"PreToolUse":[user_hook.clone()]}});
        fs::write(&config_path, original_config.to_string()).unwrap();
        let user_text = "User-owned instructions\r\nNo final newline";
        fs::write(&instructions, user_text).unwrap();
        let home_arg = home.to_str().unwrap();
        success(&invoke(&["install", host, "--home", home_arg], "", None));
        let first_config = fs::read(&config_path).unwrap();
        let first_instructions = fs::read(&instructions).unwrap();
        success(&invoke(&["install", host, "--home", home_arg], "", None));
        assert_eq!(fs::read(&config_path).unwrap(), first_config);
        assert_eq!(fs::read(&instructions).unwrap(), first_instructions);
        let config: Value = serde_json::from_slice(&first_config).unwrap();
        assert_eq!(config["custom"], original_config["custom"]);
        assert_eq!(config["hooks"]["PreToolUse"][0], user_hook);
        let state = invoke(&["status", host, "--home", home_arg], "", None);
        success(&state);
        assert_eq!(native(&state)["host_trust"], "not_observed");
        assert_eq!(native(&state)["last_observation"], Value::Null);

        // Execute the exact generated command as the host does, including
        // spaces, quotes and shell metacharacters in the installation path.
        let command = config["hooks"]["PreToolUse"][1]["hooks"][0]["command"]
            .as_str()
            .unwrap();
        let mut child = Command::new("sh")
            .args(["-c", command])
            .current_dir(&temp.0)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(
                payload("PreToolUse", "git clean -fd")
                    .to_string()
                    .as_bytes(),
            )
            .unwrap();
        let output = child.wait_with_output().unwrap();
        success(&output);
        assert_eq!(
            native(&output)["hookSpecificOutput"]["permissionDecision"],
            "deny"
        );
        assert!(!temp.0.join("SHOULD_NOT_EXIST").exists());

        success(&invoke(&["uninstall", host, "--home", home_arg], "", None));
        assert_eq!(fs::read_to_string(&instructions).unwrap(), user_text);
        let final_config: Value = serde_json::from_slice(&fs::read(&config_path).unwrap()).unwrap();
        assert_eq!(final_config["custom"], original_config["custom"]);
        assert_eq!(final_config["hooks"]["PreToolUse"], json!([user_hook]));
        assert_eq!(
            invoke(&["status", host, "--home", home_arg], "", None)
                .status
                .code(),
            Some(1)
        );
        success(&invoke(&["uninstall", host, "--home", home_arg], "", None));
    }
}

#[cfg(unix)]
#[test]
fn corrupt_config_or_instructions_fail_before_installation() {
    for (config, instructions) in [
        ("{\"token\":\"PRIVATE_SENTINEL\",", "user content"),
        ("[]", "user content"),
        ("{\"hooks\":{\"PreToolUse\":false}}", "user content"),
        ("{}", "<!-- vibeguard-core:start -->\nincomplete"),
    ] {
        let temp = Temp::new();
        let host_dir = temp.0.join(".codex");
        fs::create_dir(&host_dir).unwrap();
        let config_path = host_dir.join("hooks.json");
        let instructions_path = host_dir.join("AGENTS.md");
        fs::write(&config_path, config).unwrap();
        fs::write(&instructions_path, instructions).unwrap();
        let output = invoke(
            &["install", "codex", "--home", temp.0.to_str().unwrap()],
            "",
            None,
        );
        assert_eq!(output.status.code(), Some(2));
        assert_eq!(fs::read_to_string(&config_path).unwrap(), config);
        assert_eq!(
            fs::read_to_string(&instructions_path).unwrap(),
            instructions
        );
        assert!(!temp.0.join(".vibeguard").exists());
        assert!(!String::from_utf8_lossy(&output.stderr).contains("PRIVATE_SENTINEL"));
    }
}

#[cfg(unix)]
#[test]
fn symlinks_invalid_utf8_and_permissions_are_respected() {
    use std::os::unix::{fs::PermissionsExt, fs::symlink};
    let temp = Temp::new();
    let host_dir = temp.0.join(".codex");
    fs::create_dir(&host_dir).unwrap();
    let target = temp.0.join("user.json");
    fs::write(&target, "{}").unwrap();
    let config = host_dir.join("hooks.json");
    symlink(&target, &config).unwrap();
    assert_eq!(
        invoke(
            &["install", "codex", "--home", temp.0.to_str().unwrap()],
            "",
            None
        )
        .status
        .code(),
        Some(2)
    );
    assert_eq!(fs::read_to_string(&target).unwrap(), "{}");
    fs::remove_file(&config).unwrap();
    fs::write(&config, "{}").unwrap();
    fs::set_permissions(&config, fs::Permissions::from_mode(0o640)).unwrap();
    let instructions = host_dir.join("AGENTS.md");
    fs::write(&instructions, [0xff, 0xfe]).unwrap();
    assert_eq!(
        invoke(
            &["install", "codex", "--home", temp.0.to_str().unwrap()],
            "",
            None
        )
        .status
        .code(),
        Some(2)
    );
    assert_eq!(fs::read(&instructions).unwrap(), [0xff, 0xfe]);
    fs::write(&instructions, "user").unwrap();
    success(&invoke(
        &["install", "codex", "--home", temp.0.to_str().unwrap()],
        "",
        None,
    ));
    assert_eq!(
        fs::metadata(config).unwrap().permissions().mode() & 0o777,
        0o640
    );
}

fn git(repo: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args([
            "-c",
            "commit.gpgsign=false",
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
        ])
        .args(args)
        .output()
        .unwrap();
    success(&output);
    String::from_utf8(output.stdout).unwrap().trim().to_string()
}

#[test]
fn git_ancestry_is_checked_with_real_commits() {
    let temp = Temp::new();
    git(&temp.0, &["init", "-q"]);
    fs::write(temp.0.join("value"), "base").unwrap();
    git(&temp.0, &["add", "value"]);
    git(&temp.0, &["commit", "-qm", "base"]);
    let base = git(&temp.0, &["rev-parse", "HEAD"]);
    fs::write(temp.0.join("value"), "next").unwrap();
    git(&temp.0, &["commit", "-qam", "next"]);
    let next = git(&temp.0, &["rev-parse", "HEAD"]);
    git(&temp.0, &["checkout", "--detach", &base]);
    fs::write(temp.0.join("value"), "divergent").unwrap();
    git(&temp.0, &["commit", "-qam", "divergent"]);
    let divergent = git(&temp.0, &["rev-parse", "HEAD"]);
    let zero = "0".repeat(base.len());
    for (local, remote, exit) in [
        (&next, &base, 0),
        (&next, &zero, 0),
        (&zero, &next, 1),
        (&divergent, &next, 1),
    ] {
        let record = format!("refs/heads/main {local} refs/heads/main {remote}\n");
        assert_eq!(
            invoke(&["pre-push"], &record, Some(&temp.0)).status.code(),
            Some(exit)
        );
    }
    let missing = "1".repeat(base.len());
    let record = format!("refs/heads/main {next} refs/heads/main {missing}\n");
    assert_eq!(
        invoke(&["pre-push"], &record, Some(&temp.0)).status.code(),
        Some(2)
    );
    assert_eq!(
        invoke(&["pre-push"], "malformed\n", Some(&temp.0))
            .status
            .code(),
        Some(2)
    );
}

#[cfg(unix)]
#[test]
fn git_installer_does_not_overwrite_a_user_hook() {
    let temp = Temp::new();
    let repo = temp.0.join("repo");
    fs::create_dir(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    // Override any developer-global hook path only in this test repository.
    git(&repo, &["config", "core.hooksPath", ".git/hooks"]);
    let hook = repo.join(".git/hooks/pre-push");
    fs::write(&hook, "#!/bin/sh\necho custom\n").unwrap();
    let args = [
        "install",
        "git",
        "--repo",
        repo.to_str().unwrap(),
        "--home",
        temp.0.to_str().unwrap(),
    ];
    assert_eq!(invoke(&args, "", None).status.code(), Some(2));
    assert_eq!(
        fs::read_to_string(&hook).unwrap(),
        "#!/bin/sh\necho custom\n"
    );
    fs::remove_file(&hook).unwrap();
    success(&invoke(&args, "", None));
    assert!(fs::read_to_string(&hook).unwrap().contains("pre-push"));
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&hook, fs::Permissions::from_mode(0o644)).unwrap();
    let mut status_args = args;
    status_args[0] = "status";
    assert_eq!(invoke(&status_args, "", None).status.code(), Some(1));
    success(&invoke(&args, "", None));
    assert_ne!(fs::metadata(&hook).unwrap().permissions().mode() & 0o111, 0);
    success(&invoke(
        &[
            "status",
            "git",
            "--repo",
            repo.to_str().unwrap(),
            "--home",
            temp.0.to_str().unwrap(),
        ],
        "",
        None,
    ));
    success(&invoke(
        &[
            "uninstall",
            "git",
            "--repo",
            repo.to_str().unwrap(),
            "--home",
            temp.0.to_str().unwrap(),
        ],
        "",
        None,
    ));
    assert!(!hook.exists());
}

#[cfg(unix)]
#[test]
fn reinstall_repairs_only_owned_executable_permissions() {
    use std::os::unix::fs::PermissionsExt;
    let temp = Temp::new();
    let home = temp.0.to_str().unwrap();
    let binary = temp.0.join(".vibeguard/bin/vibeguard-runtime");
    let config = temp.0.join(".codex/hooks.json");
    success(&invoke(&["install", "codex", "--home", home], "", None));
    fs::set_permissions(&config, fs::Permissions::from_mode(0o640)).unwrap();
    for (changed, mode) in [(false, 0o644), (false, 0o655), (true, 0o644)] {
        if changed {
            fs::write(&binary, "old binary").unwrap();
        }
        fs::set_permissions(&binary, fs::Permissions::from_mode(mode)).unwrap();
        let status = invoke(&["status", "codex", "--home", home], "", None);
        assert_eq!(status.status.code(), Some(1));
        assert_eq!(native(&status)["binary_executable"], false);
        success(&invoke(&["install", "codex", "--home", home], "", None));
        success(&Command::new(&binary).arg("--version").output().unwrap());
        assert_eq!(
            fs::metadata(&config).unwrap().permissions().mode() & 0o777,
            0o640
        );
    }
}

#[cfg(not(unix))]
#[test]
fn unsupported_native_installation_is_explicit() {
    let temp = Temp::new();
    let output = invoke(
        &["install", "codex", "--home", temp.0.to_str().unwrap()],
        "",
        None,
    );
    assert_eq!(output.status.code(), Some(2));
    assert!(!temp.0.join(".codex").exists());
}
