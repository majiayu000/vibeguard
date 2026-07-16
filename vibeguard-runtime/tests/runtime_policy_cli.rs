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
fn runtime_policy_check_reports_scoped_output_filter() {
    let repo = unique_temp_dir("scoped_output_filter");
    write_policy(
        &repo,
        r#"{"scoped_suppressions":[{"hook":"post-edit-guard","rule_id":"RS-03","path":"docs/examples/**","code":"VG-POLICY-RS03-DOC-EXAMPLE","action":"suppress","reason":"Known documentation example false positive"}]}"#,
    );

    let matching_output = run_runtime_policy(&repo, "post-edit-guard.sh");
    let nonmatching_output = run_runtime_policy(&repo, "pre-bash-guard.sh");

    assert_eq!(matching_output.status.code(), Some(0));
    assert_eq!(nonmatching_output.status.code(), Some(0));
    let matching = policy_json(&matching_output);
    let nonmatching = policy_json(&nonmatching_output);
    assert_eq!(matching["decision"], "run");
    assert_eq!(matching["output_filter"], true);
    assert_eq!(nonmatching["decision"], "run");
    assert_eq!(nonmatching["output_filter"], false);
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

    let scalar = run_runtime_with_stdin(&["runtime-policy-downgrade-output"], "42");
    assert_eq!(scalar.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&scalar.stdout), "42\n");
    assert_eq!(String::from_utf8_lossy(&scalar.stderr), "");
}

#[test]
fn runtime_policy_downgrade_output_suppresses_matching_scoped_suppression() {
    let repo = unique_temp_dir("scoped_suppress");
    write_policy(
        &repo,
        r#"{"scoped_suppressions":[{"hook":"post-edit-guard","rule_id":"RS-03","path":"docs/examples/**","code":"VG-POLICY-RS03-DOC-EXAMPLE","action":"suppress","reason":"Known documentation example false positive"}]}"#,
    );

    let output = run_runtime_with_stdin(
        &[
            "runtime-policy-downgrade-output",
            "--cwd",
            repo.to_str().expect("repo path should be utf8"),
            "post-edit-guard.sh",
        ],
        r#"{"decision":"block","rule_id":"RS-03","path":"docs/examples/basic.rs","code":"VG-POLICY-RS03-DOC-EXAMPLE","reason":"unwrap blocked"}"#,
    );

    assert_eq!(output.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&output.stderr), "");
    let value: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("downgraded output should be JSON");
    assert_eq!(value["decision"], "pass");
    assert_eq!(
        value["reason"],
        "VIBEGUARD scoped suppression: Known documentation example false positive"
    );
    let _ = fs::remove_dir_all(repo);
}

#[test]
fn runtime_policy_downgrade_output_suppresses_real_posttool_payload_shape() {
    let repo = unique_temp_dir("scoped_suppress_posttool");
    write_policy(
        &repo,
        r#"{"scoped_suppressions":[{"hook":"post-edit-guard","rule_id":"RS-03","path":"docs/examples/**","action":"suppress","reason":"Known documentation example false positive"}]}"#,
    );
    let payload = repo.join("payload.json");
    let file_path = repo.join("docs/examples/basic.rs");
    fs::write(
        &payload,
        serde_json::json!({
            "hook_event_name": "PostToolUse",
            "tool_input": {
                "file_path": file_path.to_string_lossy(),
            }
        })
        .to_string(),
    )
    .expect("payload should be written");

    let output = run_runtime_with_stdin(
        &[
            "runtime-policy-downgrade-output",
            "--cwd",
            repo.to_str().expect("repo path should be utf8"),
            "--payload",
            payload.to_str().expect("payload path should be utf8"),
            "post-edit-guard.sh",
        ],
        r#"{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"VIBEGUARD quality warning: [RS-03] [review] [this-edit] OBSERVATION: 1 new unwrap()/expect() call(s) added"}}"#,
    );

    assert_eq!(output.status.code(), Some(0));
    let value: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("downgraded output should be JSON");
    assert_eq!(value["decision"], "pass");
    assert_eq!(
        value["reason"],
        "VIBEGUARD scoped suppression: Known documentation example false positive"
    );
    assert!(value.get("hookSpecificOutput").is_none());
    let _ = fs::remove_dir_all(repo);
}

#[test]
fn runtime_policy_downgrade_output_uses_config_root_for_absolute_paths() {
    let repo = unique_temp_dir("scoped_suppress_nested_cwd");
    write_policy(
        &repo,
        r#"{"scoped_suppressions":[{"hook":"post-edit-guard","rule_id":"RS-03","path":"docs/examples/**","action":"suppress","reason":"Known documentation example false positive"}]}"#,
    );
    let nested = repo.join("subdir");
    fs::create_dir_all(&nested).expect("nested cwd should be created");
    let git_init = Command::new("git")
        .arg("-C")
        .arg(&repo)
        .arg("init")
        .output()
        .expect("git init should run");
    assert!(
        git_init.status.success(),
        "git init failed: {}",
        String::from_utf8_lossy(&git_init.stderr)
    );
    let payload = repo.join("payload.json");
    let file_path = repo.join("docs/examples/basic.rs");
    fs::write(
        &payload,
        serde_json::json!({
            "hook_event_name": "PostToolUse",
            "tool_input": {
                "file_path": file_path.to_string_lossy(),
            }
        })
        .to_string(),
    )
    .expect("payload should be written");

    let output = run_runtime_with_stdin(
        &[
            "runtime-policy-downgrade-output",
            "--cwd",
            nested.to_str().expect("nested path should be utf8"),
            "--payload",
            payload.to_str().expect("payload path should be utf8"),
            "post-edit-guard.sh",
        ],
        r#"{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"VIBEGUARD quality warning: [RS-03] unwrap"}}"#,
    );

    assert_eq!(output.status.code(), Some(0));
    let value: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("downgraded output should be JSON");
    assert_eq!(value["decision"], "pass");
    assert_eq!(
        value["reason"],
        "VIBEGUARD scoped suppression: Known documentation example false positive"
    );
    let _ = fs::remove_dir_all(repo);
}

#[test]
fn runtime_policy_downgrade_output_downgrades_matching_scoped_suppression() {
    let repo = unique_temp_dir("scoped_downgrade");
    write_policy(
        &repo,
        r#"{"scoped_suppressions":[{"hook":"post-edit-guard","rule_id":"RS-03","path":"docs/examples/**","action":"downgrade_to_warn","reason":"Known documentation example false positive"}]}"#,
    );

    let output = run_runtime_with_stdin(
        &[
            "runtime-policy-downgrade-output",
            "--cwd",
            repo.to_str().expect("repo path should be utf8"),
            "post-edit-guard.sh",
        ],
        r#"{"decision":"block","rule_id":"RS-03","path":"docs/examples/basic.rs","reason":"unwrap blocked"}"#,
    );

    assert_eq!(output.status.code(), Some(0));
    let value: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("downgraded output should be JSON");
    assert_eq!(value["decision"], "warn");
    assert_eq!(
        value["reason"],
        "VIBEGUARD scoped suppression: Known documentation example false positive: unwrap blocked"
    );
    let _ = fs::remove_dir_all(repo);
}

#[test]
fn runtime_policy_downgrade_output_keeps_nonmatching_scoped_suppression_blocking() {
    let repo = unique_temp_dir("scoped_nonmatching");
    write_policy(
        &repo,
        r#"{"scoped_suppressions":[{"hook":"post-edit-guard","rule_id":"RS-03","path":"docs/examples/**","action":"suppress","reason":"Known documentation example false positive"}]}"#,
    );

    let output = run_runtime_with_stdin(
        &[
            "runtime-policy-downgrade-output",
            "--cwd",
            repo.to_str().expect("repo path should be utf8"),
            "post-edit-guard.sh",
        ],
        r#"{"decision":"block","rule_id":"RS-03","path":"src/main.rs","reason":"unwrap blocked"}"#,
    );

    assert_eq!(output.status.code(), Some(0));
    let value: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("output should remain JSON");
    assert_eq!(value["decision"], "block");
    assert_eq!(value["reason"], "unwrap blocked");
    let _ = fs::remove_dir_all(repo);
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

    let unknown = run_runtime_with_stdin(&["runtime-policy-codex-error", "Unknown"], "visible");
    let unknown_value: serde_json::Value =
        serde_json::from_slice(&unknown.stdout).expect("fallback payload should be JSON");
    assert_eq!(unknown_value["systemMessage"], "visible");
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

#[test]
fn runtime_policy_check_runs_strict_only_hook_for_strict_profile() {
    let repo = unique_temp_dir("strict_profile");
    write_policy(&repo, r#"{"profile":"strict"}"#);

    let output = run_runtime_policy(&repo, "count_active_constraints.sh");

    assert_eq!(output.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&output.stderr), "");
    let value = policy_json(&output);
    assert_eq!(value["decision"], "run");
    assert_eq!(value["profile"], "strict");
    assert_eq!(value["enforcement"], "block");
    assert!(value["reason"].is_null());

    let alias_output = bin()
        .args([
            "runtime-policy-check",
            "--project-root",
            repo.to_str().expect("repo path should be utf8"),
            "--",
            "count_active_constraints.sh",
        ])
        .env_remove("VIBEGUARD_PROJECT_CONFIG")
        .env_remove("VIBEGUARD_USER_CONFIG_FILE")
        .output()
        .expect("runtime policy command should run");
    assert_eq!(alias_output.status.code(), Some(0));
    assert_eq!(policy_json(&alias_output)["profile"], "strict");
    let _ = fs::remove_dir_all(repo);
}

#[test]
fn runtime_policy_argument_errors_are_visible() {
    let cases: &[(&[&str], &str)] = &[
        (
            &["runtime-policy-supports", "extra"],
            "runtime-policy-supports",
        ),
        (&["runtime-policy-check"], "runtime-policy-check"),
        (&["runtime-policy-check", "--cwd"], "runtime-policy-check"),
        (
            &["runtime-policy-check", "--cwd", "", "hook.sh"],
            "runtime-policy-check",
        ),
        (
            &["runtime-policy-check", "--unknown", "hook.sh"],
            "runtime-policy-check",
        ),
        (&["runtime-policy-check", "--"], "runtime-policy-check"),
        (
            &["runtime-policy-check", "--", "one.sh", "two.sh"],
            "runtime-policy-check",
        ),
        (
            &["runtime-policy-check", "one.sh", "two.sh"],
            "runtime-policy-check",
        ),
        (
            &["runtime-policy-downgrade-output", "--cwd"],
            "runtime-policy-downgrade-output",
        ),
        (
            &["runtime-policy-downgrade-output", "--payload"],
            "runtime-policy-downgrade-output",
        ),
        (
            &["runtime-policy-downgrade-output", "--unknown"],
            "runtime-policy-downgrade-output",
        ),
        (
            &[
                "runtime-policy-downgrade-output",
                "--cwd",
                "one",
                "--cwd",
                "two",
            ],
            "runtime-policy-downgrade-output",
        ),
        (
            &[
                "runtime-policy-downgrade-output",
                "--payload",
                "{}",
                "--payload",
                "{}",
            ],
            "runtime-policy-downgrade-output",
        ),
        (
            &["runtime-policy-downgrade-output", "one.sh", "two.sh"],
            "runtime-policy-downgrade-output",
        ),
        (
            &["runtime-policy-codex-error"],
            "runtime-policy-codex-error",
        ),
        (&["runtime-policy-diag"], "runtime-policy-diag"),
    ];

    for (args, command) in cases {
        let output = bin()
            .args(*args)
            .output()
            .expect("runtime helper should run");
        assert!(!output.status.success(), "{args:?} falsely succeeded");
        assert!(output.stdout.is_empty(), "{args:?}: {output:?}");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("Usage:"), "{args:?}: {stderr}");
        assert!(stderr.contains(command), "{args:?}: {stderr}");
    }

    let supports = bin()
        .arg("runtime-policy-supports")
        .output()
        .expect("runtime helper should run");
    assert!(supports.status.success());
    assert!(supports.stdout.is_empty());
    assert!(supports.stderr.is_empty());
}

#[test]
fn runtime_policy_diag_open_error_is_visible() {
    let repo = unique_temp_dir("diag_open_error");
    fs::create_dir_all(&repo).expect("diag directory should be created");

    let output = run_runtime_with_stdin(
        &[
            "runtime-policy-diag",
            repo.to_str().expect("diag path should be utf8"),
            "pre-bash-guard.sh",
            "PreToolUse",
            "policy_error",
            "run-hook-codex.sh",
        ],
        "runtime missing",
    );

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert!(!output.stderr.is_empty());
    assert!(repo.is_dir());

    let invalid_payload = run_runtime_with_stdin(
        &[
            "runtime-policy-downgrade-output",
            "--payload",
            "not-json",
            "post-edit-guard.sh",
        ],
        r#"{"decision":"block"}"#,
    );
    assert!(!invalid_payload.status.success());
    assert!(invalid_payload.stdout.is_empty());
    assert!(String::from_utf8_lossy(&invalid_payload.stderr).contains("payload invalid JSON"));
    let _ = fs::remove_dir_all(repo);
}
