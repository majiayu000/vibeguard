mod common;

use common::{hook_command, pre_bash_input, run_pre_bash_with, unique_temp_dir};
use serde_json::Value;
use std::fs;
use std::io::Write;
use std::process::Stdio;

#[test]
fn native_codex_source_new_threshold_is_advisory_with_rg_guidance() {
    let root = unique_temp_dir("hook-orchestrator-codex-source-new-threshold");
    let repo = root.join("repo");
    let log_root = root.join("logs");
    fs::create_dir_all(repo.join(".git")).unwrap();

    let run_source_new = |attempt: usize| {
        let input = serde_json::json!({
            "tool_input": {
                "file_path": repo.join(format!("src/native_codex_{attempt}.rs")),
                "content": "fn native_codex_source() {}\n"
            }
        })
        .to_string();
        let mut child = hook_command(&repo, &log_root)
            .env("VIBEGUARD_CALLER_EVIDENCE", "codex-hook-payload")
            .env("VIBEGUARD_WRITE_MODE", "warn")
            .env("VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD", "2")
            .env("VG_CB_THRESHOLD", "100")
            .args(["hook", "pre-write"])
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
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        output
    };

    let _ = run_source_new(1);
    let _ = run_source_new(2);
    let threshold_output = run_source_new(3);
    let threshold_stdout = String::from_utf8_lossy(&threshold_output.stdout);
    let threshold_response: Value = serde_json::from_slice(&threshold_output.stdout).unwrap();
    assert_eq!(threshold_response["decision"], "warn", "{threshold_stdout}");

    let symbol_audit = "rg -n 'native_codex_source' .";
    let same_name_audit = "rg --files . | rg '(^|/)native_codex_3\\.rs$'";
    for audit_command in [symbol_audit, same_name_audit] {
        let audit_output = run_pre_bash_with(
            &repo,
            &log_root,
            &pre_bash_input(audit_command),
            |command| {
                command.env("VIBEGUARD_CALLER_EVIDENCE", "codex-hook-payload");
            },
        );
        assert_eq!(
            audit_output.status.code(),
            Some(0),
            "supported Codex audit should be allowed: {}",
            String::from_utf8_lossy(&audit_output.stderr)
        );
        assert!(
            audit_output.stdout.is_empty(),
            "allowed pre-bash audit should not emit a policy response: {}",
            String::from_utf8_lossy(&audit_output.stdout)
        );
    }

    let retry_output = run_source_new(4);
    let stdout = String::from_utf8_lossy(&retry_output.stdout);
    let response: Value = serde_json::from_slice(&retry_output.stdout).unwrap();
    assert_eq!(response["decision"], "warn", "{stdout}");
    assert!(stdout.contains("Bash"), "{stdout}");
    assert!(stdout.contains("rg -n"), "{stdout}");
    assert!(stdout.contains("rg --files . | rg"), "{stdout}");
    assert!(!stdout.contains("Grep"), "{stdout}");
    assert!(!stdout.contains("Glob"), "{stdout}");
    assert!(!stdout.contains("persistent global"), "{stdout}");

    let project_dir = fs::read_dir(log_root.join("projects"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let events = fs::read_to_string(project_dir.join("events.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    let audit_events = events
        .iter()
        .filter(|event| event["hook"] == "pre-bash-guard")
        .collect::<Vec<_>>();
    assert_eq!(audit_events.len(), 2, "{events:?}");
    assert!(audit_events.iter().all(|event| event["decision"] == "pass"));
    assert_eq!(audit_events[0]["detail"], symbol_audit);
    assert_eq!(audit_events[1]["detail"], same_name_audit);
    let threshold_event = events.last().unwrap();
    assert_eq!(threshold_event["cli"], "codex");
    assert_eq!(threshold_event["caller_evidence"], "codex-hook-payload");
    assert_eq!(threshold_event["decision"], "warn");
    assert_eq!(threshold_event["status"], "warn");

    let _ = fs::remove_dir_all(root);
}
