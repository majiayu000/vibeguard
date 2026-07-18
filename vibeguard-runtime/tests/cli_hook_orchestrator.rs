mod common;

use common::{bin, unique_temp_dir};
use serde_json::Value;
use std::fs;
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

fn run_hook(repo: &Path, log_root: &Path, hook: &str, input: &str) -> Output {
    let mut child = hook_command(repo, log_root)
        .args(["hook", hook])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn run_hook_without_ci(repo: &Path, log_root: &Path, hook: &str, input: &str) -> Output {
    let mut command = hook_command(repo, log_root);
    for name in [
        "CI",
        "GITHUB_ACTIONS",
        "TRAVIS",
        "CIRCLECI",
        "JENKINS_URL",
        "GITLAB_CI",
        "TF_BUILD",
    ] {
        command.env_remove(name);
    }
    let mut child = command
        .args(["hook", hook])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn hook_command(repo: &Path, log_root: &Path) -> Command {
    let mut command = bin();
    command
        .current_dir(repo)
        .env("VIBEGUARD_LOG_DIR", log_root)
        .env("VIBEGUARD_CLI", "codex")
        .env("VIBEGUARD_SESSION_ID", "session-test")
        .env("VIBEGUARD_CALLER_EVIDENCE", "explicit-test")
        .env("VIBEGUARD_WRAPPER", "test-wrapper")
        .env("VIBEGUARD_SOURCE_CONFIG", "test-config")
        .env("VIBEGUARD_HOOK_PROTOCOL_VERSION", "1");
    command
}

fn run_pre_bash_with(
    repo: &Path,
    log_root: &Path,
    input: &str,
    configure: impl FnOnce(&mut Command),
) -> Output {
    let mut command = hook_command(repo, log_root);
    configure(&mut command);
    let mut child = command
        .args(["hook", "pre-bash"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn pre_bash_input(command: &str) -> String {
    serde_json::json!({"tool_input": {"command": command}}).to_string()
}

fn run_pre_bash_case(
    label: &str,
    input: &str,
    configure: impl FnOnce(&mut Command),
) -> (PathBuf, PathBuf, Output) {
    let root = unique_temp_dir(label);
    let repo = root.join("repo");
    let log_root = root.join("logs");
    fs::create_dir_all(repo.join(".git")).unwrap();
    let output = run_pre_bash_with(&repo, &log_root, input, configure);
    (root, log_root, output)
}

fn first_project_event(log_root: &Path) -> Value {
    let project_dir = fs::read_dir(log_root.join("projects"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    read_first_json(&project_dir.join("events.jsonl"))
}

#[cfg(unix)]
fn write_executable(path: &Path, body: &str) {
    fs::write(path, body).unwrap();
    let mut permissions = fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
}

fn git(repo: &Path, args: &[&str]) {
    let output = Command::new("git")
        .current_dir(repo)
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn read_first_json(path: &Path) -> Value {
    let text = fs::read_to_string(path).unwrap();
    let first = text.lines().next().unwrap();
    serde_json::from_str(first).unwrap()
}

#[test]
fn hook_orchestrator_writes_project_and_global_events() {
    let root = unique_temp_dir("hook-orchestrator-pass");
    let repo = root.join("repo");
    let log_root = root.join("logs");
    fs::create_dir_all(repo.join(".git")).unwrap();
    fs::create_dir_all(repo.join("src")).unwrap();

    let input = serde_json::json!({
        "tool_input": {
            "command": "git status"
        }
    })
    .to_string();
    let out = run_hook(&repo, &log_root, "pre-bash", &input);
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(out.stdout.is_empty());

    let projects_dir = log_root.join("projects");
    let project_entries = fs::read_dir(&projects_dir).unwrap().collect::<Vec<_>>();
    assert_eq!(project_entries.len(), 1);
    let project_dir = project_entries[0].as_ref().unwrap().path();
    let project_log = project_dir.join("events.jsonl");
    let global_log = log_root.join("events.jsonl");
    assert_eq!(
        fs::read_to_string(&project_log).unwrap(),
        fs::read_to_string(&global_log).unwrap()
    );
    assert_eq!(
        fs::read_to_string(project_dir.join(".project-root")).unwrap(),
        fs::canonicalize(&repo).unwrap().to_string_lossy()
    );

    let event = read_first_json(&project_log);
    assert_eq!(event["hook"], "pre-bash-guard");
    assert_eq!(event["tool"], "Bash");
    assert_eq!(event["decision"], "pass");
    assert_eq!(event["status"], "pass");
    assert_eq!(event["session"], "session-test");
    assert_eq!(event["cli"], "codex");
    assert_eq!(event["client"], "codex");
    assert_eq!(event["client_variant"], "codex-cli-hooks");
    assert_eq!(event["caller_evidence"], "explicit-test");
    assert_eq!(event["wrapper"], "test-wrapper");
    assert_eq!(event["source_config"], "test-config");
    assert_eq!(event["hook_protocol_version"], "1");
    assert_eq!(event["detail"], "git status");
    assert!(event["duration_ms"].as_u64().is_some(), "{event}");
    assert_eq!(event["project_hash"].as_str().unwrap().len(), 8);

    let _ = fs::remove_dir_all(root);
}

#[test]
fn hook_orchestrator_honors_log_file_overrides() {
    let root = unique_temp_dir("hook-orchestrator-overrides");
    let repo = root.join("repo");
    let log_root = root.join("logs");
    let project_log_dir = root.join("explicit-project");
    let log_file = project_log_dir.join("events.jsonl");
    fs::create_dir_all(repo.join(".git")).unwrap();

    let mut child = hook_command(&repo, &log_root)
        .args(["hook", "pre-bash"])
        .env("VIBEGUARD_PROJECT_LOG_DIR", &project_log_dir)
        .env("VIBEGUARD_LOG_FILE", &log_file)
        .env("VIBEGUARD_PROJECT_HASH", "feedface")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(br#"{"tool_input":{"command":"git status"}}"#)
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(0));

    let event = read_first_json(&log_file);
    assert_eq!(event["hook"], "pre-bash-guard");
    assert_eq!(event["tool"], "Bash");
    assert_eq!(event["detail"], "git status");
    assert_eq!(event["project_hash"], "feedface");
    assert!(log_root.join("events.jsonl").exists());

    let _ = fs::remove_dir_all(root);
}

#[test]
fn hook_orchestrator_malformed_input_fails_closed() {
    let root = unique_temp_dir("hook-orchestrator-malformed");
    let repo = root.join("repo");
    let log_root = root.join("logs");
    fs::create_dir_all(repo.join(".git")).unwrap();

    let out = run_hook(&repo, &log_root, "pre-write-guard", "not-json");
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("\"decision\": \"block\""), "{stdout}");
    assert!(
        stdout.contains("malformed PreToolUse(Write) hook input"),
        "{stdout}"
    );

    let project_dir = fs::read_dir(log_root.join("projects"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let event = read_first_json(&project_dir.join("events.jsonl"));
    assert_eq!(event["hook"], "pre-write-guard");
    assert_eq!(event["decision"], "block");
    assert_eq!(event["status"], "block");

    let _ = fs::remove_dir_all(root);
}

#[test]
fn hook_orchestrator_malformed_input_blocks_even_when_context_collection_fails() {
    let root = unique_temp_dir("hook-orchestrator-malformed-context-failure");
    let repo = root.join("repo");
    let log_root = root.join("logs");
    let bad_parent = root.join("not-a-dir");
    let bad_project_log_dir = bad_parent.join("project");
    let bad_log_file = bad_project_log_dir.join("events.jsonl");
    fs::create_dir_all(repo.join(".git")).unwrap();
    fs::write(&bad_parent, "not a directory").unwrap();

    let mut child = hook_command(&repo, &log_root)
        .args(["hook", "pre-write"])
        .env("VIBEGUARD_PROJECT_LOG_DIR", &bad_project_log_dir)
        .env("VIBEGUARD_LOG_FILE", &bad_log_file)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(b"not-json")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("\"decision\":\"block\""), "{stdout}");
    assert!(
        stdout.contains("runtime orchestrator failed to collect runtime context"),
        "{stdout}"
    );
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("runtime orchestrator failed to collect runtime context"),
        "{stderr}"
    );

    let _ = fs::remove_dir_all(root);
}

#[test]
fn hook_orchestrator_pre_write_source_new_logs_attempt_and_reminder() {
    let root = unique_temp_dir("hook-orchestrator-prewrite-source-new");
    let repo = root.join("repo");
    let log_root = root.join("logs");
    fs::create_dir_all(repo.join(".git")).unwrap();

    let input = serde_json::json!({
        "tool_input": {
            "file_path": repo.join("src/new_file.rs"),
            "content": "fn new_file() {}\n"
        }
    })
    .to_string();
    let out = run_hook(&repo, &log_root, "pre-write", &input);
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("hookSpecificOutput"), "{stdout}");
    assert!(stdout.contains("new source file detected"), "{stdout}");

    let project_dir = fs::read_dir(log_root.join("projects"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let project_log = project_dir.join("events.jsonl");
    let global_log = log_root.join("events.jsonl");
    assert_eq!(
        fs::read_to_string(&project_log).unwrap(),
        fs::read_to_string(&global_log).unwrap()
    );
    let events = fs::read_to_string(&project_log).unwrap();
    let reasons = events
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .map(|event| event["reason"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    assert!(
        reasons
            .iter()
            .any(|reason| reason == "New source file attempt"),
        "{reasons:?}"
    );
    assert!(
        reasons
            .iter()
            .any(|reason| reason == "New source file reminder"),
        "{reasons:?}"
    );

    let _ = fs::remove_dir_all(root);
}

#[test]
fn hook_orchestrator_pre_edit_pass_logs_compatible_event() {
    let root = unique_temp_dir("hook-orchestrator-preedit-pass");
    let repo = root.join("repo");
    let log_root = root.join("logs");
    fs::create_dir_all(repo.join(".git")).unwrap();
    fs::create_dir_all(repo.join("src")).unwrap();
    let file_path = repo.join("src/lib.rs");
    fs::write(&file_path, "pub fn value() -> i32 { 1 }\n").unwrap();

    let input = serde_json::json!({
        "tool_input": {
            "file_path": file_path,
            "old_string": ""
        }
    })
    .to_string();
    let out = run_hook(&repo, &log_root, "pre-edit", &input);
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(out.stdout.is_empty());

    let project_dir = fs::read_dir(log_root.join("projects"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let project_log = project_dir.join("events.jsonl");
    let log_text = fs::read_to_string(&project_log).unwrap();
    assert!(
        log_text.contains("\"hook\": \"pre-edit-guard\""),
        "{log_text}"
    );
    assert!(log_text.contains("\"decision\": \"pass\""), "{log_text}");

    let event = read_first_json(&project_log);
    assert_eq!(event["hook"], "pre-edit-guard");
    assert_eq!(event["tool"], "Edit");
    assert_eq!(event["decision"], "pass");
    assert_eq!(event["status"], "pass");
    assert_eq!(event["detail"], file_path.to_string_lossy().as_ref());

    let _ = fs::remove_dir_all(root);
}

#[test]
fn hook_orchestrator_pre_bash_blocks_and_logs_reason() {
    let root = unique_temp_dir("hook-orchestrator-prebash-block");
    let repo = root.join("repo");
    let log_root = root.join("logs");
    fs::create_dir_all(repo.join(".git")).unwrap();

    let input = serde_json::json!({
        "tool_input": {
            "command": "git checkout ."
        }
    })
    .to_string();
    let out = run_hook(&repo, &log_root, "pre-bash", &input);
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("\"decision\": \"block\""), "{stdout}");
    assert!(stdout.contains("authorized-discard.py"), "{stdout}");

    let project_dir = fs::read_dir(log_root.join("projects"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let event = read_first_json(&project_dir.join("events.jsonl"));
    assert_eq!(event["hook"], "pre-bash-guard");
    assert_eq!(event["tool"], "Bash");
    assert_eq!(event["decision"], "block");
    assert_eq!(event["status"], "block");
    assert!(
        event["reason"]
            .as_str()
            .unwrap()
            .contains("Disable git checkout/restore"),
        "{event}"
    );
    assert_eq!(event["detail"], "git checkout .");

    let _ = fs::remove_dir_all(root);
}

#[test]
fn hook_orchestrator_stop_logs_uncommitted_source_changes() {
    let root = unique_temp_dir("hook-orchestrator-stop-gate");
    let repo = root.join("repo");
    let log_root = root.join("logs");
    fs::create_dir_all(repo.join("src")).unwrap();
    git(&repo, &["init"]);
    git(&repo, &["config", "user.email", "test@example.com"]);
    git(&repo, &["config", "user.name", "Test User"]);
    fs::write(repo.join("src/lib.rs"), "pub fn value() -> i32 { 1 }\n").unwrap();
    git(&repo, &["add", "src/lib.rs"]);
    git(&repo, &["commit", "-m", "initial"]);
    fs::write(repo.join("src/lib.rs"), "pub fn value() -> i32 { 2 }\n").unwrap();

    let out = run_hook_without_ci(&repo, &log_root, "stop", r#"{"hook_event_name":"Stop"}"#);
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(out.stdout.is_empty());

    let project_dir = fs::read_dir(log_root.join("projects"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let event = read_first_json(&project_dir.join("events.jsonl"));
    assert_eq!(event["hook"], "stop-guard");
    assert_eq!(event["tool"], "Stop");
    assert_eq!(event["decision"], "gate");
    assert_eq!(event["status"], "gate");
    assert_eq!(event["reason"], "uncommitted source changes: 1 files");
    assert_eq!(event["detail"], "src/lib.rs ");

    let _ = fs::remove_dir_all(root);
}

#[test]
fn hook_orchestrator_manual_session_without_cli_stays_unknown() {
    let root = unique_temp_dir("hook-orchestrator-manual-session");
    let repo = root.join("repo");
    let log_root = root.join("logs");
    fs::create_dir_all(repo.join(".git")).unwrap();

    let mut child = hook_command(&repo, &log_root)
        .args(["hook", "pre-bash"])
        .env_remove("VIBEGUARD_CLI")
        .env_remove("VIBEGUARD_CLIENT")
        .env_remove("VIBEGUARD_CLIENT_VARIANT")
        .env_remove("VIBEGUARD_CALLER_EVIDENCE")
        .env("VIBEGUARD_SESSION_ID", "manual-session")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(br#"{"tool_input":{"command":"echo manual"}}"#)
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let project_dir = fs::read_dir(log_root.join("projects"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let event = read_first_json(&project_dir.join("events.jsonl"));
    assert_eq!(event["session"], "manual-session");
    assert_eq!(event["cli"], "unknown");
    assert_eq!(event["client"], "unknown");
    assert_eq!(event["client_variant"], "unknown");
    assert_eq!(event["caller_evidence"], "no-client-evidence");

    let _ = fs::remove_dir_all(root);
}

fn assert_pre_bash_log_failure(label: &str, input: &str, configure: impl FnOnce(&mut Command)) {
    let bad_log = unique_temp_dir(&format!("{label}-bad-log"));
    let project_log = unique_temp_dir(&format!("{label}-project-log"));
    fs::create_dir_all(&bad_log).unwrap();
    let (root, _, out) = run_pre_bash_case(label, input, |command| {
        configure(command);
        command
            .env("VIBEGUARD_PROJECT_LOG_DIR", &project_log)
            .env("VIBEGUARD_LOG_FILE", &bad_log);
    });
    assert_eq!(out.status.code(), Some(1), "{label}");
    assert!(out.stdout.is_empty(), "{label}");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("vibeguard-runtime error:"),
        "{label}: {stderr}"
    );
    let _ = fs::remove_dir_all(root);
    let _ = fs::remove_dir_all(project_log);
    let _ = fs::remove_dir_all(bad_log);
}

#[test]
fn pre_bash_malformed_missing_warning_and_root_precedence() {
    for (label, input) in [
        ("prebash-malformed", "not-json"),
        ("prebash-missing-command", r#"{"tool_input":{}}"#),
    ] {
        let (root, logs, out) = run_pre_bash_case(label, input, |_| {});
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(stdout.contains("\"decision\": \"block\""), "{stdout}");
        assert_eq!(first_project_event(&logs)["decision"], "block");
        let _ = fs::remove_dir_all(root);
    }
    let input = pre_bash_input("printf x > notes.md");
    let (root, logs, out) = run_pre_bash_case("prebash-warning", &input, |_| {});
    assert!(String::from_utf8_lossy(&out.stdout).contains("non-standard .md file"));
    assert_eq!(first_project_event(&logs)["decision"], "warn");
    let _ = fs::remove_dir_all(root);

    let input = pre_bash_input("git checkout .");
    let (root, _, out) = run_pre_bash_case("prebash-root-precedence", &input, |command| {
        command
            .env("VIBEGUARD_DIR", "/explicit-vg-root")
            .env("VIBEGUARD_HOOK_DIR", "/ignored-vg-root/hooks");
    });
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("/explicit-vg-root/scripts/authorized-discard.py"));
    assert!(!stdout.contains("/ignored-vg-root"));
    let _ = fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn pre_bash_correction_paths_preserve_behavior() {
    let empty_path = unique_temp_dir("prebash-empty-path");
    fs::create_dir_all(&empty_path).unwrap();
    let input = pre_bash_input("npm install");
    let (root, logs, out) = run_pre_bash_case("prebash-no-path", &input, |command| {
        command.env("PATH", &empty_path);
    });
    assert!(out.stdout.is_empty());
    assert_eq!(
        first_project_event(&logs)["reason"],
        "pkg-rewrite skipped (pnpm not found)"
    );
    let _ = fs::remove_dir_all(root);
    let _ = fs::remove_dir_all(empty_path);

    let tools = unique_temp_dir("prebash-tools");
    fs::create_dir_all(&tools).unwrap();
    write_executable(&tools.join("uv"), "#!/bin/sh\nexit 0\n");
    write_executable(&tools.join("pnpm"), "#!/bin/sh\nexit 0\n");
    let input = pre_bash_input("pip install requests");
    let (root, logs, out) = run_pre_bash_case("prebash-uv-skip", &input, |command| {
        command.env("PATH", &tools).env_remove("VIRTUAL_ENV");
    });
    assert!(out.stdout.is_empty());
    assert!(
        first_project_event(&logs)["reason"]
            .as_str()
            .unwrap()
            .contains("no active venv")
    );
    let _ = fs::remove_dir_all(root);

    let input = pre_bash_input("npm install");
    let (root, logs, out) = run_pre_bash_case("prebash-correction", &input, |command| {
        command.env("PATH", &tools);
    });
    assert!(String::from_utf8_lossy(&out.stdout).contains("pnpm install"));
    assert_eq!(first_project_event(&logs)["decision"], "correction");
    let _ = fs::remove_dir_all(root);
    let _ = fs::remove_dir_all(tools);
}

#[cfg(unix)]
#[test]
fn pre_bash_precommit_outcomes_preserve_behavior() {
    for (label, script) in [
        ("prebash-precommit-ok", Some("echo checked\nexit 0\n")),
        ("prebash-no-script", None),
    ] {
        let hooks = unique_temp_dir(label).join("hooks");
        fs::create_dir_all(&hooks).unwrap();
        if let Some(body) = script {
            fs::write(hooks.join("pre-commit-guard.sh"), body).unwrap();
        }
        let input = pre_bash_input("git commit -m ok");
        let (root, logs, out) = run_pre_bash_case(label, &input, |command| {
            command.env("VIBEGUARD_HOOK_DIR", &hooks);
        });
        assert!(out.stdout.is_empty());
        assert_eq!(first_project_event(&logs)["decision"], "pass");
        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(hooks.parent().unwrap());
    }

    let hooks = unique_temp_dir("prebash-precommit-fail").join("hooks");
    fs::create_dir_all(&hooks).unwrap();
    fs::write(
        hooks.join("pre-commit-guard.sh"),
        "echo child-stdout\necho child-stderr >&2\nexit 7\n",
    )
    .unwrap();
    let input = pre_bash_input("git commit -m fail");
    let (root, logs, out) = run_pre_bash_case("prebash-precommit-fail", &input, |command| {
        command.env("VIBEGUARD_HOOK_DIR", &hooks);
    });
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("child-stdout") && stdout.contains("child-stderr"));
    assert_eq!(first_project_event(&logs)["decision"], "block");
    let _ = fs::remove_dir_all(root);

    let empty_path = unique_temp_dir("prebash-spawn-empty-path");
    fs::create_dir_all(&empty_path).unwrap();
    let (root, logs, out) = run_pre_bash_case("prebash-spawn-fail", &input, |command| {
        command
            .env("VIBEGUARD_HOOK_DIR", &hooks)
            .env("PATH", &empty_path);
    });
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("\"decision\": \"block\"") && stdout.contains("Pre-Commit"));
    assert_eq!(first_project_event(&logs)["decision"], "block");
    let _ = fs::remove_dir_all(root);
    let _ = fs::remove_dir_all(empty_path);
    let _ = fs::remove_dir_all(hooks.parent().unwrap());
}

#[cfg(unix)]
#[test]
fn pre_bash_all_append_errors_propagate() {
    assert_pre_bash_log_failure("prebash-log-block", "not-json", |_| {});
    let warning = pre_bash_input("printf x > notes.md");
    assert_pre_bash_log_failure("prebash-log-warn", &warning, |_| {});
    let correction = pre_bash_input("npm install");
    assert_pre_bash_log_failure("prebash-log-missing-tool", &correction, |command| {
        command.env_remove("PATH");
    });
    let tools = unique_temp_dir("prebash-log-tools");
    fs::create_dir_all(&tools).unwrap();
    write_executable(&tools.join("uv"), "#!/bin/sh\nexit 0\n");
    write_executable(&tools.join("pnpm"), "#!/bin/sh\nexit 0\n");
    let uv = pre_bash_input("pip install requests");
    assert_pre_bash_log_failure("prebash-log-uv-skip", &uv, |command| {
        command.env("PATH", &tools).env_remove("VIRTUAL_ENV");
    });
    assert_pre_bash_log_failure("prebash-log-correction", &correction, |command| {
        command.env("PATH", &tools);
    });

    let hooks = unique_temp_dir("prebash-log-hooks").join("hooks");
    fs::create_dir_all(&hooks).unwrap();
    fs::write(hooks.join("pre-commit-guard.sh"), "exit 9\n").unwrap();
    let commit = pre_bash_input("git commit -m fail");
    assert_pre_bash_log_failure("prebash-log-precommit", &commit, |command| {
        command.env("VIBEGUARD_HOOK_DIR", &hooks);
    });
    let empty_path = unique_temp_dir("prebash-log-empty-path");
    fs::create_dir_all(&empty_path).unwrap();
    assert_pre_bash_log_failure("prebash-log-spawn", &commit, |command| {
        command
            .env("VIBEGUARD_HOOK_DIR", &hooks)
            .env("PATH", &empty_path);
    });
    let pass = pre_bash_input("echo ok");
    assert_pre_bash_log_failure("prebash-log-pass", &pass, |_| {});
    let _ = fs::remove_dir_all(tools);
    let _ = fs::remove_dir_all(hooks.parent().unwrap());
    let _ = fs::remove_dir_all(empty_path);
}

#[test]
fn pre_bash_empty_and_pass_preserve_behavior() {
    let input = pre_bash_input("");
    let (root, logs, out) = run_pre_bash_case("prebash-empty", &input, |_| {});
    assert!(out.stdout.is_empty());
    let project = fs::read_dir(logs.join("projects"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    assert!(!project.join("events.jsonl").exists());
    let _ = fs::remove_dir_all(root);

    let input = pre_bash_input("echo ok");
    let (root, logs, out) = run_pre_bash_case("prebash-pass", &input, |_| {});
    assert!(out.stdout.is_empty());
    assert_eq!(first_project_event(&logs)["decision"], "pass");
    let _ = fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn pre_bash_deleted_cwd_uses_defensive_fallbacks() {
    let root = unique_temp_dir("prebash-deleted-cwd");
    let (repo, logs) = (root.join("repo"), root.join("logs"));
    fs::create_dir_all(repo.join(".git")).unwrap();
    let mut command = hook_command(&repo, &logs);
    command.args(["hook", "pre-bash"]).stdin(Stdio::piped());
    let mut child = command.spawn().unwrap();
    fs::remove_dir_all(&repo).unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(pre_bash_input("git commit -m deleted-cwd").as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(0));
    assert!(out.stdout.is_empty());
    assert_eq!(first_project_event(&logs)["decision"], "pass");
    let _ = fs::remove_dir_all(root);
}
