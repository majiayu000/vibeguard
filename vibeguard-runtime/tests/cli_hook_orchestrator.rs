mod common;

use common::{bin, unique_temp_dir};
use serde_json::Value;
use std::fs;
use std::io::Write;
use std::path::Path;
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
