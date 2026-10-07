use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

const BIN: &str = env!("CARGO_BIN_EXE_vibeguard-runtime");
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "vibeguard-grok-{}-{}",
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

fn invoke(args: &[&str], input: &Value) -> Output {
    let mut command = Command::new(BIN);
    command.args(args);
    run(command, input)
}
fn run(mut command: Command, input: &Value) -> Output {
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.to_string().as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}
fn success(output: &Output) {
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}
fn value(output: &Output) -> Value {
    serde_json::from_slice(&output.stdout).unwrap()
}
// Wire fields from xai-org/grok-build's HookEventEnvelope / HookPayload.
fn payload(event: &str, command: &str) -> Value {
    json!({
        "hookEventName":event,"cwd":"/fixture","toolName":"run_terminal_command",
        "toolInput":{"command":command},"toolUseId":"grok-call",
        "toolInputTruncated":false
    })
}

#[test]
fn native_and_claude_imported_hooks_allow_and_deny_without_executing_input() {
    let dir = Temp::new();
    let sentinel = dir.0.join("must-not-be-executed");
    for host in ["grok", "claude"] {
        for command in [
            "ls",
            "git clean -nfd",
            &format!("touch {}", sentinel.display()),
        ] {
            let output = invoke(&["hook", host], &payload("pre_tool_use", command));
            success(&output);
            assert!(output.stdout.is_empty());
        }
        for command in ["git clean -fd", "git restore .", "rm -rf /"] {
            let output = invoke(&["hook", host], &payload("pre_tool_use", command));
            success(&output);
            assert_eq!(
                value(&output)["hookSpecificOutput"]["permissionDecision"],
                "deny"
            );
            assert_eq!(
                value(&output)["hookSpecificOutput"]["hookEventName"],
                "PreToolUse"
            );
        }
    }
    assert!(!sentinel.exists());
    assert_eq!(
        invoke(&["hook", "codex"], &payload("pre_tool_use", "ls"))
            .status
            .code(),
        Some(2)
    );
}

#[test]
fn documented_aliases_and_canonical_precedence_do_not_bypass_policy() {
    let alias = json!({"hook_event_name":"PreToolUse","cwd":"/fixture",
        "tool_name":"run_terminal_command","tool_input":{"command":"git clean -fd"}});
    for host in ["grok", "claude"] {
        assert_eq!(
            value(&invoke(&["hook", host], &alias))["hookSpecificOutput"]["permissionDecision"],
            "deny"
        );
        let mut conflicting = payload("pre_tool_use", "git clean -fd");
        conflicting["hook_event_name"] = json!("PostToolUse");
        conflicting["tool_name"] = json!("Bash");
        conflicting["tool_input"] = json!({"command":"ls"});
        assert_eq!(
            value(&invoke(&["hook", host], &conflicting))["hookSpecificOutput"]["permissionDecision"],
            "deny"
        );
    }
}

#[test]
fn malformed_unknown_and_truncated_pre_events_remain_errors_without_leaks() {
    let base = payload("pre_tool_use", "PRIVATE_SENTINEL");
    let mut inputs = vec![Value::Null, json!({})];
    for (key, replacement) in [
        ("toolName", json!("read_file")),
        ("toolName", Value::Null),
        ("hookEventName", json!("stop")),
        ("cwd", json!(" ")),
        ("toolInput", json!({"command":42})),
        ("toolInput", json!("clipped")),
        ("toolInputTruncated", json!(true)),
    ] {
        let mut input = base.clone();
        input[key] = replacement;
        inputs.push(input);
    }
    for host in ["grok", "claude"] {
        for input in &inputs {
            let output = invoke(&["hook", host], input);
            assert_eq!(output.status.code(), Some(2));
            assert!(output.stdout.is_empty());
            assert!(!String::from_utf8_lossy(&output.stderr).contains("PRIVATE_SENTINEL"));
        }
    }
}

#[test]
fn observations_use_grok_identity_and_structured_results_only() {
    let dir = Temp::new();
    let state = dir.0.to_str().unwrap();
    for host in ["grok", "claude"] {
        for (response, outcome, code) in [
            (
                json!({"type":"Bash","exit_code":0}),
                "exited_zero",
                json!(0),
            ),
            (
                json!({"type":"Bash","exit_code":7}),
                "exited_nonzero",
                json!(7),
            ),
            (
                json!("exit_code: 0 PRIVATE_RESULT"),
                "exit_status_unavailable",
                Value::Null,
            ),
            (Value::Null, "exit_status_unavailable", Value::Null),
        ] {
            let mut input = payload("post_tool_use", "PRIVATE_COMMAND");
            input["toolInput"] = json!("truncated input");
            input["toolInputTruncated"] = json!(true);
            input["toolResult"] = response;
            success(&invoke(&["hook", host, "--state-dir", state], &input));
            let text = fs::read_to_string(dir.0.join("grok.json")).unwrap();
            let observed: Value = serde_json::from_str(&text).unwrap();
            assert_eq!(observed["host"], "grok");
            assert_eq!(observed["tool"], "run_terminal_command");
            assert_eq!(observed["tool_use_id"], "grok-call");
            assert_eq!(observed["event"], "PostToolUse");
            assert_eq!(observed["outcome"], outcome);
            assert_eq!(observed["exit_code"], code);
            assert!(!text.contains("PRIVATE_"));
            assert!(!dir.0.join("claude.json").exists());
        }
        for (flag, outcome) in [
            ("isBackgrounded", "running"),
            ("toolResultTruncated", "exit_status_unavailable"),
        ] {
            let mut input = payload("post_tool_use", "ls");
            input["toolResult"] = json!({"exit_code":0});
            input[flag] = json!(true);
            success(&invoke(&["hook", host, "--state-dir", state], &input));
            let observed: Value =
                serde_json::from_slice(&fs::read(dir.0.join("grok.json")).unwrap()).unwrap();
            assert_eq!(observed["outcome"], outcome);
            assert!(observed["exit_code"].is_null());
        }
        for interrupted in [false, true] {
            let mut input = payload("post_tool_use_failure", "ls");
            input["error"] = json!("PRIVATE_ERROR");
            input["isInterrupt"] = json!(interrupted);
            success(&invoke(&["hook", host, "--state-dir", state], &input));
            let observed: Value =
                serde_json::from_slice(&fs::read(dir.0.join("grok.json")).unwrap()).unwrap();
            assert_eq!(
                observed["outcome"],
                if interrupted { "interrupted" } else { "failed" }
            );
            assert!(!observed.to_string().contains("PRIVATE_ERROR"));
        }
    }
    let mut missing = payload("post_tool_use", "ls");
    assert_eq!(invoke(&["hook", "grok"], &missing).status.code(), Some(2));
    missing["toolResult"] = json!({"exit_code":"0"});
    assert_eq!(invoke(&["hook", "grok"], &missing).status.code(), Some(2));
    let missing_error = payload("post_tool_use_failure", "ls");
    assert_eq!(
        invoke(&["hook", "grok"], &missing_error).status.code(),
        Some(2)
    );
}

#[test]
fn optional_observation_failure_preserves_grok_policy() {
    let dir = Temp::new();
    let state = dir.0.join("file");
    fs::write(&state, b"user data").unwrap();
    for host in ["grok", "claude"] {
        for (command, denied) in [("ls", false), ("git clean -fd", true)] {
            let output = invoke(
                &["hook", host, "--state-dir", state.to_str().unwrap()],
                &payload("pre_tool_use", command),
            );
            success(&output);
            let output = value(&output);
            assert!(output["systemMessage"].is_string());
            assert_eq!(
                output["hookSpecificOutput"]["permissionDecision"] == "deny",
                denied
            );
        }
    }
    assert_eq!(fs::read(state).unwrap(), b"user data");
}

#[cfg(unix)]
#[test]
fn native_installation_roundtrip_preserves_user_files_and_executes_registrations() {
    let dir = Temp::new();
    let home = dir.0.join("developer's home $(touch SHOULD_NOT_EXIST)");
    let grok = home.join(".grok");
    fs::create_dir_all(grok.join("hooks")).unwrap();
    fs::create_dir_all(grok.join("rules")).unwrap();
    let config_path = grok.join("hooks/vibeguard.json");
    let instructions = grok.join("rules/vibeguard.md");
    let user_hook =
        json!({"matcher":"read_file","hooks":[{"type":"command","command":"echo user"}]});
    let original = json!({"custom":42,"hooks":{"PreToolUse":[user_hook.clone()]}});
    fs::write(&config_path, original.to_string()).unwrap();
    fs::write(
        grok.join("config.toml"),
        "# untouched\n[compat.claude]\nhooks = true\n",
    )
    .unwrap();
    fs::write(grok.join("hooks/user.json"), "{\"hooks\":{}}\n").unwrap();
    let user_text = "user instructions\r\nwithout final newline";
    fs::write(&instructions, user_text).unwrap();
    let home_arg = home.to_str().unwrap();
    let install = || invoke(&["install", "grok", "--home", home_arg], &Value::Null);
    success(&install());
    let config_bytes = fs::read(&config_path).unwrap();
    let instructions_bytes = fs::read(&instructions).unwrap();
    success(&install());
    assert_eq!(fs::read(&config_path).unwrap(), config_bytes);
    assert_eq!(fs::read(&instructions).unwrap(), instructions_bytes);
    assert_eq!(instructions_bytes, user_text.as_bytes());
    let status = invoke(&["status", "grok", "--home", home_arg], &Value::Null);
    success(&status);
    assert_eq!(value(&status)["host_trust"], "not_observed");
    let config: Value = serde_json::from_slice(&config_bytes).unwrap();
    assert_eq!(config["custom"], 42);
    assert_eq!(config["hooks"]["PreToolUse"][0], user_hook);
    for (event, native_event) in [
        ("PreToolUse", "pre_tool_use"),
        ("PostToolUse", "post_tool_use"),
        ("PostToolUseFailure", "post_tool_use_failure"),
    ] {
        let group = config["hooks"][event].as_array().unwrap().last().unwrap();
        assert_eq!(group["matcher"], "run_terminal_command");
        let mut shell = Command::new("sh");
        shell
            .args(["-c", group["hooks"][0]["command"].as_str().unwrap()])
            .current_dir(&dir.0);
        let mut input = payload(native_event, "git clean -fd");
        if event == "PostToolUse" {
            input["toolResult"] = json!({"exit_code":0});
        }
        if event == "PostToolUseFailure" {
            input["error"] = json!("dispatch failed");
        }
        let output = run(shell, &input);
        success(&output);
        if event == "PreToolUse" {
            assert_eq!(
                value(&output)["hookSpecificOutput"]["permissionDecision"],
                "deny"
            );
        }
    }
    assert!(!dir.0.join("SHOULD_NOT_EXIST").exists());
    let status = value(&invoke(
        &["status", "grok", "--home", home_arg],
        &Value::Null,
    ));
    assert_eq!(status["last_observation"]["outcome"], "failed");
    fs::write(&instructions, "stale instructions\n").unwrap();
    assert_eq!(
        invoke(&["status", "grok", "--home", home_arg], &Value::Null)
            .status
            .code(),
        Some(0)
    );
    success(&install());
    success(&invoke(
        &["status", "grok", "--home", home_arg],
        &Value::Null,
    ));
    success(&invoke(
        &["uninstall", "grok", "--home", home_arg],
        &Value::Null,
    ));
    assert_eq!(
        fs::read_to_string(&instructions).unwrap(),
        "stale instructions\n"
    );
    let final_config: Value = serde_json::from_slice(&fs::read(&config_path).unwrap()).unwrap();
    assert_eq!(final_config["hooks"]["PreToolUse"], json!([user_hook]));
    assert_eq!(final_config["custom"], 42);
    assert_eq!(
        fs::read_to_string(grok.join("config.toml")).unwrap(),
        "# untouched\n[compat.claude]\nhooks = true\n"
    );
    assert_eq!(
        fs::read_to_string(grok.join("hooks/user.json")).unwrap(),
        "{\"hooks\":{}}\n"
    );
    assert!(home.join(".vibeguard/bin/vibeguard-runtime").is_file());
    assert!(!home.join(".vibeguard/state/grok.json").exists());
    assert_eq!(
        invoke(&["status", "grok", "--home", home_arg], &Value::Null)
            .status
            .code(),
        Some(1)
    );
    success(&invoke(
        &["uninstall", "grok", "--home", home_arg],
        &Value::Null,
    ));
}

#[cfg(unix)]
#[test]
fn grok_home_override_is_honored_and_explicit_home_is_isolated() {
    let dir = Temp::new();
    let home = dir.0.join("home");
    let custom = dir.0.join("custom-grok");
    let mut install = Command::new(BIN);
    install
        .args(["install", "grok"])
        .env("HOME", &home)
        .env("GROK_HOME", &custom);
    success(&run(install, &Value::Null));
    assert!(custom.join("hooks/vibeguard.json").exists());
    assert!(!custom.join("rules/vibeguard.md").exists());
    assert!(!home.join(".grok").exists());
    let isolated = dir.0.join("isolated");
    let mut command = Command::new(BIN);
    command
        .args(["install", "grok", "--home"])
        .arg(&isolated)
        .env("GROK_HOME", &custom);
    success(&run(command, &Value::Null));
    assert!(isolated.join(".grok/hooks/vibeguard.json").exists());
}

#[cfg(unix)]
#[test]
fn corrupt_and_symlink_grok_targets_fail_before_installation() {
    use std::os::unix::fs::symlink;
    for original in ["PRIVATE_SENTINEL invalid JSON", "[]"] {
        let dir = Temp::new();
        let path = dir.0.join(".grok/hooks/vibeguard.json");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, original).unwrap();
        let output = invoke(
            &["install", "grok", "--home", dir.0.to_str().unwrap()],
            &Value::Null,
        );
        assert_eq!(output.status.code(), Some(2));
        assert!(!String::from_utf8_lossy(&output.stderr).contains("PRIVATE_SENTINEL"));
        assert_eq!(fs::read_to_string(path).unwrap(), original);
        assert!(!dir.0.join(".vibeguard").exists());
    }
    let dir = Temp::new();
    let target = dir.0.join("user.json");
    fs::write(&target, "{}").unwrap();
    fs::create_dir_all(dir.0.join(".grok/hooks")).unwrap();
    symlink(&target, dir.0.join(".grok/hooks/vibeguard.json")).unwrap();
    let output = invoke(
        &["install", "grok", "--home", dir.0.to_str().unwrap()],
        &Value::Null,
    );
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(fs::read_to_string(target).unwrap(), "{}");
    assert!(!dir.0.join(".vibeguard").exists());
}

#[cfg(not(unix))]
#[test]
fn unsupported_grok_native_installation_fails_without_writes() {
    let dir = Temp::new();
    let output = invoke(
        &["install", "grok", "--home", dir.0.to_str().unwrap()],
        &Value::Null,
    );
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 0);
}
