use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"))
}

fn unique_temp_dir(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "vibeguard-runtime-policy-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

fn write_policy(repo: &Path, body: &str) {
    fs::create_dir_all(repo).expect("repo temp dir should be created");
    fs::write(repo.join(".vibeguard.json"), body).expect("project policy should be written");
}

fn run_runtime_with_stdin(args: &[&str], input: &str) -> std::process::Output {
    let mut child = bin()
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("runtime helper should spawn");
    child
        .stdin
        .as_mut()
        .expect("stdin should be piped")
        .write_all(input.as_bytes())
        .expect("runtime helper stdin should be written");
    child
        .wait_with_output()
        .expect("runtime helper should finish")
}

fn run_runtime_policy(repo: &Path, hook_name: &str) -> std::process::Output {
    bin()
        .arg("runtime-policy-check")
        .arg("--cwd")
        .arg(repo)
        .arg(hook_name)
        .current_dir(repo)
        .env_remove("VIBEGUARD_PROJECT_CONFIG")
        .env_remove("VIBEGUARD_USER_CONFIG_FILE")
        .output()
        .expect("runtime policy command should run")
}

fn policy_json(output: &std::process::Output) -> serde_json::Value {
    serde_json::from_slice(&output.stdout).unwrap_or_else(|err| {
        panic!(
            "runtime-policy-check stdout should be JSON: {err}; stdout={}; stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    })
}

#[test]
fn runtime_policy_check_allows_when_no_project_config_exists() {
    let repo = unique_temp_dir("allow_no_config");
    fs::create_dir_all(&repo).expect("repo temp dir should be created");

    let output = run_runtime_policy(&repo, "pre-bash-guard.sh");

    assert_eq!(output.status.code(), Some(0));
    let value = policy_json(&output);
    assert_eq!(value["decision"], "run");
    assert_eq!(value["enforcement"], "block");
    assert_eq!(value["hook"], "pre-bash-guard.sh");
    assert_eq!(value["profile"], "core");
    assert!(value["config_path"].is_null());
    assert!(value["reason"].is_null());
    assert_eq!(String::from_utf8_lossy(&output.stderr), "");
    let _ = fs::remove_dir_all(repo);
}

#[test]
fn runtime_policy_check_uses_explicit_cwd_instead_of_process_cwd() {
    let repo = unique_temp_dir("explicit_cwd");
    let other = unique_temp_dir("process_cwd");
    write_policy(&repo, r#"{"enforcement":"warn"}"#);
    fs::create_dir_all(&other).expect("process cwd should be created");

    let output = bin()
        .arg("runtime-policy-check")
        .arg("--cwd")
        .arg(&repo)
        .arg("pre-bash-guard.sh")
        .current_dir(&other)
        .env_remove("VIBEGUARD_PROJECT_CONFIG")
        .env_remove("VIBEGUARD_USER_CONFIG_FILE")
        .output()
        .expect("runtime policy command should run");

    assert_eq!(output.status.code(), Some(0));
    let value = policy_json(&output);
    assert_eq!(value["decision"], "run");
    assert_eq!(value["enforcement"], "warn");
    assert_eq!(value["cwd"], repo.to_string_lossy().as_ref());
    assert_eq!(
        value["config_path"],
        repo.join(".vibeguard.json").to_string_lossy().as_ref()
    );
    assert_eq!(String::from_utf8_lossy(&output.stderr), "");
    let _ = fs::remove_dir_all(repo);
    let _ = fs::remove_dir_all(other);
}

#[test]
fn runtime_policy_check_skips_disabled_hook() {
    let repo = unique_temp_dir("disabled_hook");
    write_policy(&repo, r#"{"disabled_hooks":["pre-bash-guard"]}"#);

    let output = run_runtime_policy(&repo, "vibeguard-pre-bash-guard.sh");

    assert_eq!(output.status.code(), Some(10));
    let value = policy_json(&output);
    assert_eq!(value["decision"], "skip");
    assert_eq!(value["enforcement"], "block");
    assert!(
        value["reason"]
            .as_str()
            .unwrap_or("")
            .contains("disabled_hooks contains pre-bash-guard")
    );
    assert_eq!(String::from_utf8_lossy(&output.stderr), "");
    let _ = fs::remove_dir_all(repo);
}

#[test]
fn runtime_policy_check_reports_warn_enforcement() {
    let repo = unique_temp_dir("warn_enforcement");
    write_policy(&repo, r#"{"enforcement":"warn"}"#);

    let output = run_runtime_policy(&repo, "pre-bash-guard.sh");

    assert_eq!(output.status.code(), Some(0));
    let value = policy_json(&output);
    assert_eq!(value["decision"], "run");
    assert_eq!(value["enforcement"], "warn");
    assert_eq!(value["reason"], "VibeGuard policy warn: enforcement=warn");
    assert_eq!(String::from_utf8_lossy(&output.stderr), "");
    let _ = fs::remove_dir_all(repo);
}

#[test]
fn runtime_policy_check_validates_user_runtime_config_before_policy() {
    let repo = unique_temp_dir("bad_user_config");
    write_policy(&repo, r#"{}"#);
    let user_config = repo.join("bad-config.json");
    fs::write(&user_config, r#"{"write_mode":"#).expect("runtime config should be written");

    let output = bin()
        .arg("runtime-policy-check")
        .arg("--cwd")
        .arg(&repo)
        .arg("pre-bash-guard.sh")
        .current_dir(&repo)
        .env_remove("VIBEGUARD_PROJECT_CONFIG")
        .env("VIBEGUARD_USER_CONFIG_FILE", &user_config)
        .output()
        .expect("runtime policy command should run");

    assert_eq!(output.status.code(), Some(30));
    let value = policy_json(&output);
    assert_eq!(value["decision"], "error");
    assert!(
        value["reason"]
            .as_str()
            .unwrap_or("")
            .contains("runtime config invalid JSON")
    );
    assert!(String::from_utf8_lossy(&output.stderr).contains("runtime config invalid JSON"));
    let _ = fs::remove_dir_all(repo);
}

#[test]
fn runtime_policy_check_reports_project_schema_errors_as_policy_errors() {
    let repo = unique_temp_dir("bad_project_schema");
    write_policy(&repo, r#"{"disabled_hooks":["missing-hook"]}"#);

    let output = run_runtime_policy(&repo, "pre-bash-guard.sh");

    assert_eq!(output.status.code(), Some(20));
    let value = policy_json(&output);
    assert_eq!(value["decision"], "error");
    assert!(value["enforcement"].is_null());
    assert!(value["profile"].is_null());
    assert!(
        value["reason"]
            .as_str()
            .unwrap_or("")
            .contains("disabled_hooks contains unsupported hook")
    );
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("disabled_hooks contains unsupported hook")
    );
    let _ = fs::remove_dir_all(repo);
}

#[test]
fn runtime_policy_check_reports_project_json_parse_errors_as_config_parse_errors() {
    let repo = unique_temp_dir("bad_project_json");
    write_policy(&repo, r#"{"disabled_hooks":"#);

    let output = run_runtime_policy(&repo, "pre-bash-guard.sh");

    assert_eq!(output.status.code(), Some(30));
    let value = policy_json(&output);
    assert_eq!(value["decision"], "error");
    assert!(value["enforcement"].is_null());
    assert!(
        value["reason"]
            .as_str()
            .unwrap_or("")
            .contains("project config invalid JSON")
    );
    assert!(String::from_utf8_lossy(&output.stderr).contains("project config invalid JSON"));
    let _ = fs::remove_dir_all(repo);
}

#[test]
fn runtime_policy_check_reports_project_utf8_errors_as_config_parse_errors() {
    let repo = unique_temp_dir("bad_project_utf8");
    fs::create_dir_all(&repo).expect("repo temp dir should be created");
    fs::write(repo.join(".vibeguard.json"), [0xff, 0xfe])
        .expect("invalid utf8 project policy should be written");

    let output = run_runtime_policy(&repo, "pre-bash-guard.sh");

    assert_eq!(output.status.code(), Some(30));
    let value = policy_json(&output);
    assert_eq!(value["decision"], "error");
    assert!(
        value["reason"]
            .as_str()
            .unwrap_or("")
            .contains("project config invalid UTF-8")
    );
    assert!(String::from_utf8_lossy(&output.stderr).contains("project config invalid UTF-8"));
    let _ = fs::remove_dir_all(repo);
}

#[test]
fn runtime_policy_check_uses_shared_profile_filtering_for_strict_only_hooks() {
    let repo = unique_temp_dir("strict_only");
    write_policy(&repo, r#"{"profile":"core"}"#);

    let output = run_runtime_policy(&repo, "count_active_constraints.sh");

    assert_eq!(output.status.code(), Some(10));
    let value = policy_json(&output);
    assert_eq!(value["decision"], "skip");
    assert_eq!(value["profile"], "core");
    assert!(
        value["reason"]
            .as_str()
            .unwrap_or("")
            .contains("profile=core excludes count-active-constraints")
    );
    let _ = fs::remove_dir_all(repo);
}

#[test]
fn runtime_policy_downgrade_output_converts_block_to_warn() {
    let output = run_runtime_with_stdin(
        &["runtime-policy-downgrade-output"],
        r#"{"decision":"block","reason":"dangerous command"}"#,
    );

    assert_eq!(output.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&output.stderr), "");
    let value: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("downgraded output should be JSON");
    assert_eq!(value["decision"], "warn");
    assert_eq!(
        value["reason"],
        "VIBEGUARD warn-mode advisory: dangerous command"
    );
}

#[test]
fn runtime_policy_downgrade_output_removes_codex_pretool_denial() {
    let output = run_runtime_with_stdin(
        &["runtime-policy-downgrade-output"],
        r#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"blocked by policy"}}"#,
    );

    assert_eq!(output.status.code(), Some(0));
    let value: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("downgraded output should be JSON");
    assert_eq!(
        value["systemMessage"],
        "VIBEGUARD warn-mode advisory: blocked by policy"
    );
    assert!(value["hookSpecificOutput"]["permissionDecision"].is_null());
    assert!(value["hookSpecificOutput"]["permissionDecisionReason"].is_null());
}

#[test]
fn runtime_policy_downgrade_output_removes_codex_permission_denial() {
    let output = run_runtime_with_stdin(
        &["runtime-policy-downgrade-output"],
        r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"permission denied"}}}"#,
    );

    assert_eq!(output.status.code(), Some(0));
    let value: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("downgraded output should be JSON");
    assert_eq!(
        value["systemMessage"],
        "VIBEGUARD warn-mode advisory: permission denied"
    );
    assert!(value["hookSpecificOutput"]["decision"].is_null());
}

#[test]
fn runtime_policy_downgrade_output_preserves_non_json_text() {
    let output = run_runtime_with_stdin(&["runtime-policy-downgrade-output"], "not json");

    assert_eq!(output.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&output.stdout), "not json\n");
    assert_eq!(String::from_utf8_lossy(&output.stderr), "");
}

#[test]
fn runtime_policy_codex_error_outputs_event_specific_payloads() {
    let pretool = run_runtime_with_stdin(
        &["runtime-policy-codex-error", "PreToolUse"],
        "project config invalid",
    );
    let pretool_value: serde_json::Value =
        serde_json::from_slice(&pretool.stdout).expect("PreToolUse payload should be JSON");
    assert_eq!(
        pretool_value["hookSpecificOutput"]["permissionDecision"],
        "deny"
    );
    assert_eq!(
        pretool_value["hookSpecificOutput"]["permissionDecisionReason"],
        "project config invalid"
    );

    let permission = run_runtime_with_stdin(
        &["runtime-policy-codex-error", "PermissionRequest"],
        "policy denied",
    );
    let permission_value: serde_json::Value = serde_json::from_slice(&permission.stdout)
        .expect("PermissionRequest payload should be JSON");
    assert_eq!(
        permission_value["hookSpecificOutput"]["decision"]["behavior"],
        "deny"
    );
    assert_eq!(
        permission_value["hookSpecificOutput"]["decision"]["message"],
        "policy denied"
    );

    let posttool = run_runtime_with_stdin(
        &["runtime-policy-codex-error", "PostToolUse"],
        "posttool denied",
    );
    let posttool_value: serde_json::Value =
        serde_json::from_slice(&posttool.stdout).expect("PostToolUse payload should be JSON");
    assert_eq!(posttool_value["decision"], "block");
    assert_eq!(
        posttool_value["hookSpecificOutput"]["additionalContext"],
        "posttool denied"
    );

    let stop = run_runtime_with_stdin(&["runtime-policy-codex-error", "Stop"], "stop denied");
    let stop_value: serde_json::Value =
        serde_json::from_slice(&stop.stdout).expect("Stop payload should be JSON");
    assert_eq!(stop_value["stopReason"], "stop denied");
}

#[test]
fn runtime_policy_diag_appends_jsonl_event() {
    let repo = unique_temp_dir("diag");
    fs::create_dir_all(&repo).expect("diag dir should be created");
    let diag_file = repo.join("policy.jsonl");

    let output = run_runtime_with_stdin(
        &[
            "runtime-policy-diag",
            diag_file.to_str().expect("diag path should be utf8"),
            "pre-bash-guard.sh",
            "PreToolUse",
            "policy_error",
            "run-hook-codex.sh",
        ],
        "runtime missing",
    );

    assert_eq!(output.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&output.stderr), "");
    let line = fs::read_to_string(&diag_file).expect("diag event should be written");
    let value: serde_json::Value =
        serde_json::from_str(line.trim()).expect("diag event should be JSON");
    assert!(value["ts"].as_str().unwrap_or("").ends_with('Z'));
    assert_eq!(value["wrapper"], "run-hook-codex.sh");
    assert_eq!(value["hook"], "pre-bash-guard.sh");
    assert_eq!(value["event"], "PreToolUse");
    assert_eq!(value["kind"], "policy_error");
    assert_eq!(value["reason"], "runtime missing");
    let _ = fs::remove_dir_all(repo);
}
