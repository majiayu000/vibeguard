mod common;

use common::{bin, unique_temp_dir};
use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

fn fixture_root(label: &str) -> PathBuf {
    let root = unique_temp_dir(label);
    fs::create_dir_all(root.join("home")).expect("fixture root should be created");
    root
}

fn command(root: &Path) -> Command {
    let mut command = bin();
    command
        .current_dir(root)
        .env("HOME", root.join("home"))
        .env_remove("VIBEGUARD_CODEX_DIAG_FILE")
        .env_remove("VIBEGUARD_LOG_DIR")
        .stdin(Stdio::null());
    command
}

fn run(root: &Path, args: &[&str]) -> Output {
    command(root)
        .args(args)
        .output()
        .expect("hook-status command should run")
}

fn run_with_stdin(root: &Path, args: &[&str], input: &str) -> Output {
    let mut child = command(root)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("hook-status command should spawn");
    child
        .stdin
        .as_mut()
        .expect("stdin should be piped")
        .write_all(input.as_bytes())
        .expect("stdin fixture should be written");
    child
        .wait_with_output()
        .expect("hook-status command should finish")
}

fn write_jsonl(path: &Path, values: &[Value]) {
    let text = values
        .iter()
        .map(Value::to_string)
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";
    fs::write(path, text).expect("JSONL fixture should be written");
}

fn output_text(output: &Output) -> (String, String) {
    (
        String::from_utf8(output.stdout.clone()).expect("stdout should be UTF-8"),
        String::from_utf8(output.stderr.clone()).expect("stderr should be UTF-8"),
    )
}

fn json_output(output: &Output) -> Value {
    assert!(output.status.success(), "{output:?}");
    assert!(output.stderr.is_empty(), "{output:?}");
    serde_json::from_slice(&output.stdout).expect("hook-status stdout should be JSON")
}

fn entry_by_detail<'a>(payload: &'a Value, detail: &str) -> &'a Value {
    payload["entries"]
        .as_array()
        .expect("entries should be an array")
        .iter()
        .find(|entry| entry["detail"] == detail)
        .unwrap_or_else(|| panic!("missing entry detail {detail:?}: {payload}"))
}

#[test]
fn argument_contract_rejects_invalid_mode_limit_slow_scope_and_filters() {
    let root = fixture_root("hook-status-args");
    let cases = [
        (&["hook-status", "--mode"][..], "--mode requires"),
        (
            &["hook-status", "--mode", "wide"][..],
            "mode must be one of",
        ),
        (&["hook-status", "--limit"][..], "--limit requires"),
        (&["hook-status", "--limit", "0"][..], "greater than 0"),
        (&["hook-status", "--limit", "x"][..], "invalid digit"),
        (&["hook-status", "--slow-ms"][..], "--slow-ms requires"),
        (&["hook-status", "--slow-ms", "x"][..], "invalid digit"),
        (&["hook-status", "--scope"][..], "--scope requires"),
        (
            &["hook-status", "--scope", "team"][..],
            "scope must be one of: project, global",
        ),
        (&["hook-status", "--project"][..], "--project requires"),
        (&["hook-status", "--log-file"][..], "--log-file requires"),
        (&["hook-status", "--diag-file"][..], "--diag-file requires"),
        (&["hook-status", "--session"][..], "--session requires"),
        (&["hook-status", "--event"][..], "--event requires"),
        (
            &["hook-status", "--unknown"][..],
            "unknown hook-status argument",
        ),
        (
            &["hook-status", "--help"][..],
            "Usage: vibeguard-runtime hook-status",
        ),
    ];
    for (args, expected) in cases {
        let output = run(&root, args);
        let (stdout, stderr) = output_text(&output);
        assert!(!output.status.success(), "{args:?} falsely succeeded");
        assert!(stdout.is_empty(), "{args:?}: {stdout}");
        assert!(stderr.contains(expected), "{args:?}: {stderr}");
    }
    fs::remove_dir_all(root).expect("fixture should be removed");
}

#[test]
fn reads_explicit_files_stdin_implicit_no_data_and_bounded_tail() {
    let root = fixture_root("hook-status-read");
    let missing = root.join("missing.jsonl");
    let diag = root.join("missing-diag.jsonl");
    let missing_output = run(
        &root,
        &[
            "hook-status",
            "--log-file",
            missing.to_str().unwrap(),
            "--diag-file",
            diag.to_str().unwrap(),
        ],
    );
    assert!(!missing_output.status.success());
    assert!(missing_output.stdout.is_empty());
    assert!(!missing_output.stderr.is_empty());

    let directory = root.join("events-dir");
    fs::create_dir(&directory).expect("directory fixture should be created");
    let directory_output = run(
        &root,
        &[
            "hook-status",
            "--log-file",
            directory.to_str().unwrap(),
            "--diag-file",
            diag.to_str().unwrap(),
        ],
    );
    assert!(!directory_output.status.success());
    assert!(!directory_output.stderr.is_empty());

    let empty_log = root.join("empty-events.jsonl");
    fs::write(&empty_log, "").expect("empty event log should be written");
    let diag_directory = root.join("diag-dir");
    fs::create_dir(&diag_directory).expect("diagnostic directory should be created");
    let diag_directory_output = run(
        &root,
        &[
            "hook-status",
            "--log-file",
            empty_log.to_str().unwrap(),
            "--diag-file",
            diag_directory.to_str().unwrap(),
        ],
    );
    assert!(!diag_directory_output.status.success());
    assert!(diag_directory_output.stdout.is_empty());
    assert!(!diag_directory_output.stderr.is_empty());

    let log_root = root.join("logs");
    fs::create_dir(&log_root).expect("log root should be created");
    let implicit = command(&root)
        .args([
            "hook-status",
            "--scope",
            "global",
            "--diag-file",
            diag.to_str().unwrap(),
        ])
        .env("VIBEGUARD_LOG_DIR", &log_root)
        .output()
        .expect("implicit no-data command should run");
    let (implicit_stdout, implicit_stderr) = output_text(&implicit);
    assert!(implicit.status.success(), "{implicit:?}");
    assert!(implicit_stderr.is_empty());
    assert!(implicit_stdout.contains("No hook status events found in"));
    assert!(implicit_stdout.contains("events.jsonl"));

    let project_log = log_root.join("projects/abc12345/events.jsonl");
    fs::create_dir_all(project_log.parent().unwrap()).expect("project log dir should be created");
    write_jsonl(
        &project_log,
        &[
            json!({"ts":"2026-06-01T00:00:00Z","hook":"project-hook","decision":"pass","detail":"project-data"}),
        ],
    );
    let project = command(&root)
        .args([
            "hook-status",
            "--json",
            "--project",
            "abc12345",
            "--diag-file",
            diag.to_str().unwrap(),
        ])
        .env("VIBEGUARD_LOG_DIR", &log_root)
        .output()
        .expect("project-scope command should run");
    assert_eq!(
        json_output(&project)["entries"][0]["detail"],
        "project-data"
    );

    let stdin = run_with_stdin(
        &root,
        &[
            "hook-status",
            "--json",
            "--mode",
            "minimal",
            "--diag-file",
            diag.to_str().unwrap(),
        ],
        "not-json\n{\"ts\":\"2026-06-01T00:00:00Z\",\"hook\":\"pre-bash-guard\",\"tool\":\"Bash\",\"decision\":\"pass\",\"detail\":\"stdin-valid\"}\n",
    );
    let stdin_json = json_output(&stdin);
    assert_eq!(stdin_json["entries"].as_array().unwrap().len(), 1);
    assert_eq!(stdin_json["entries"][0]["log_path"], "stdin");

    let tail = root.join("tail.jsonl");
    let mut text = String::from(
        "{\"ts\":\"2026-06-01T00:00:00Z\",\"session\":\"old\",\"hook\":\"old-hook\",\"detail\":\"old-target\"}\nmalformed\n",
    );
    for index in 0..205 {
        text.push_str(&format!(
            "{{\"ts\":\"2026-06-01T00:01:{:02}Z\",\"session\":\"recent\",\"hook\":\"recent-hook\",\"decision\":\"pass\",\"detail\":\"recent-{index}\"}}\n",
            index % 60
        ));
    }
    fs::write(&tail, text).expect("tail fixture should be written");
    let recent = json_output(&run(
        &root,
        &[
            "hook-status",
            "--json",
            "--limit",
            "1",
            "--log-file",
            tail.to_str().unwrap(),
            "--diag-file",
            diag.to_str().unwrap(),
        ],
    ));
    assert_eq!(recent["entries"].as_array().unwrap().len(), 1);
    assert!(
        recent["entries"][0]["detail"]
            .as_str()
            .unwrap()
            .starts_with("recent-")
    );
    let old = json_output(&run(
        &root,
        &[
            "hook-status",
            "--json",
            "--limit",
            "1",
            "--session",
            "old",
            "--log-file",
            tail.to_str().unwrap(),
            "--diag-file",
            diag.to_str().unwrap(),
        ],
    ));
    assert_eq!(old["entries"][0]["detail"], "old-target");
    fs::remove_dir_all(root).expect("fixture should be removed");
}

#[test]
fn normalizes_hook_and_diag_fields_statuses_reasons_and_model_context() {
    let root = fixture_root("hook-status-normalize");
    let log = root.join("events.jsonl");
    let diag = root.join("diag.jsonl");
    write_jsonl(
        &log,
        &[
            json!({"ts":"2026-06-01T00:00:01Z","session":"s1","hook":"vibeguard-pre-bash-guard.sh","tool":"Bash","decision":"pass","detail":"pass","duration_ms":"18"}),
            json!({"ts":"2026-06-01T00:00:02Z","session":"s1","hook":"post-write-guard","tool":"Write","decision":"pass","detail":"slow","duration_ms":2500}),
            json!({"ts":"2026-06-01T00:00:03Z","session":"s1","hook":"post-edit-guard","tool":"Edit","decision":"warn","reason":"unwrap found","detail":"warn","elapsed_ms":44}),
            json!({"ts":"2026-06-01T00:00:04Z","session":"s1","hook":"pre-write-guard","hookEventName":"PermissionRequest","matcher":"Write","status":"block","reason":"blocked","detail":"block","timeout_ms":"30000"}),
            json!({"ts":"2026-06-01T00:00:05Z","session":"s1","hook":"post-build-check","tool":"PostToolUse","decision":"pass","reason":"skip: missing file_path","detail":"skip","duration_ms":28}),
            json!({"ts":"2026-06-01T00:00:06Z","session":"s1","hook":"post-build-check","event":"PostToolUse","decision":"warn","reason":"hook timeout after 30s","detail":"timeout","duration_ms":30000}),
        ],
    );
    write_jsonl(
        &diag,
        &[
            json!({"ts":"2026-06-01T00:00:07Z","session":"d1","hook":"diag-explicit","event":"Stop","matcher":"","status":"correction","decision":"correction","reason":"fix","detail":"diag-explicit","duration_ms":"1500","elapsed_ms":"1600","timeout_ms":"5000"}),
            json!({"ts":"2026-06-01T00:00:08Z","hook":"diag-adapter","event":"PostToolUse","reason":"missing-runner","detail":"diag-adapter"}),
            json!({"ts":"2026-06-01T00:00:09Z","hook":"diag-hook-error","event":"PostToolUse","reason":"unexpected","detail":"diag-hook-error"}),
        ],
    );
    let payload = json_output(&run(
        &root,
        &[
            "hook-status",
            "--json",
            "--mode",
            "full",
            "--slow-ms",
            "2000",
            "--log-file",
            log.to_str().unwrap(),
            "--diag-file",
            diag.to_str().unwrap(),
        ],
    ));
    assert_eq!(payload["schema_version"], 1);
    assert_eq!(payload["mode"], "full");
    let pass = entry_by_detail(&payload, "pass");
    assert_eq!(pass["event"], "PreToolUse");
    assert_eq!(pass["matcher"], "Bash");
    assert_eq!(pass["status"], "pass");
    assert_eq!(pass["duration_ms"], 18);
    assert_eq!(pass["model_context"], false);
    assert_eq!(entry_by_detail(&payload, "slow")["status"], "slow");
    let warn = entry_by_detail(&payload, "warn");
    assert_eq!(warn["event"], "PostToolUse");
    assert_eq!(warn["matcher"], "Edit");
    assert_eq!(warn["elapsed_ms"], 44);
    assert_eq!(warn["model_context"], true);
    let block = entry_by_detail(&payload, "block");
    assert_eq!(block["event"], "PermissionRequest");
    assert_eq!(block["timeout_ms"], 30000);
    assert_eq!(block["model_context"], true);
    let skipped = entry_by_detail(&payload, "skip");
    assert_eq!(skipped["status"], "skipped");
    assert_eq!(skipped["reason"], "missing file_path");
    assert_eq!(entry_by_detail(&payload, "timeout")["status"], "timeout");
    let explicit = entry_by_detail(&payload, "diag-explicit");
    assert_eq!(explicit["source"], "codex_diag");
    assert_eq!(explicit["matcher"], "<none>");
    assert_eq!(explicit["elapsed_ms"], 1600);
    assert_eq!(explicit["model_context"], true);
    assert_eq!(
        entry_by_detail(&payload, "diag-adapter")["status"],
        "adapter_error"
    );
    assert_eq!(
        entry_by_detail(&payload, "diag-hook-error")["status"],
        "hook_error"
    );
    fs::remove_dir_all(root).expect("fixture should be removed");
}

#[test]
fn filters_limits_orders_and_drops_stale_running_by_canonical_hook() {
    let root = fixture_root("hook-status-filter-order");
    let log = root.join("events.jsonl");
    let diag = root.join("diag.jsonl");
    write_jsonl(
        &log,
        &[
            json!({"ts":"2026-06-01T00:00:01Z","session":"s1","hook":"pre-bash-guard","event":"PreToolUse","decision":"pass","detail":"first"}),
            json!({"ts":"2026-06-01T00:00:02Z","session":"s2","hook":"post-build-check","event":"PostToolUse","decision":"warn","detail":"filtered-session"}),
            json!({"ts":"2026-06-01T00:00:03Z","session":"s1","hook":"vibeguard-post-build-check.sh","event":"PostToolUse","decision":"pass","detail":"completed"}),
            json!({"ts":"2026-06-01T00:00:04Z","session":"s1","hook":"last-hook","event":"Stop","decision":"complete","detail":"last"}),
        ],
    );
    write_jsonl(
        &diag,
        &[
            json!({"ts":"2026-06-01T00:00:03Z","hook":"post-build-check","event":"PostToolUse","status":"running","detail":"stale-running","elapsed_ms":12000,"timeout_ms":30000}),
        ],
    );
    let filtered = json_output(&run(
        &root,
        &[
            "hook-status",
            "--json",
            "--limit",
            "2",
            "--session",
            "s1",
            "--event",
            "PostToolUse",
            "--log-file",
            log.to_str().unwrap(),
            "--diag-file",
            diag.to_str().unwrap(),
        ],
    ));
    let entries = filtered["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["detail"], "completed");

    let latest = json_output(&run(
        &root,
        &[
            "hook-status",
            "--json",
            "--limit",
            "2",
            "--log-file",
            log.to_str().unwrap(),
            "--diag-file",
            diag.to_str().unwrap(),
        ],
    ));
    assert_eq!(latest["entries"].as_array().unwrap().len(), 2);
    assert_eq!(latest["entries"][0]["detail"], "completed");
    assert_eq!(latest["entries"][1]["detail"], "last");
    assert!(
        latest.to_string().find("completed").unwrap() < latest.to_string().find("last").unwrap()
    );
    assert!(!latest.to_string().contains("stale-running"));
    fs::remove_dir_all(root).expect("fixture should be removed");
}

#[test]
fn renders_minimal_focused_full_and_json_no_data_deterministically() {
    let root = fixture_root("hook-status-render");
    let log = root.join("events.jsonl");
    let diag = root.join("missing-diag.jsonl");
    write_jsonl(
        &log,
        &[
            json!({"ts":"2026-06-01T00:00:01Z","hook":"post-edit-guard","event":"PostToolUse","matcher":"Edit","decision":"warn","reason":"review","detail":"src/lib.rs","duration_ms":500}),
            json!({"ts":"2026-06-01T00:00:02Z","hook":"post-write-guard","event":"PostToolUse","matcher":"Write","decision":"pass","detail":"src/main.rs","duration_ms":2000}),
            json!({"ts":"2026-06-01T00:00:03Z","hook":"post-build-check","event":"PostToolUse","matcher":"Bash","status":"timeout","reason":"timeout","detail":"cargo test","duration_ms":2500}),
            json!({"ts":"2026-06-01T00:00:04Z","hook":"quick-pass","event":"PostToolUse","status":"pass","detail":"pass action","duration_ms":100}),
            json!({"ts":"2026-06-01T00:00:05Z","hook":"explicit-skip","event":"PostToolUse","status":"skipped","reason":"skipped: not needed","detail":"skip action"}),
            json!({"ts":"2026-06-01T00:00:06Z","hook":"explicit-block","event":"PostToolUse","status":"block","reason":"denied","detail":"block action"}),
            json!({"ts":"2026-06-01T00:00:07Z","hook":"hook-failure","event":"PostToolUse","status":"hook_error","reason":"failed","detail":"error action"}),
            json!({"ts":"2026-06-01T00:00:08Z","hook":"still-running","event":"PostToolUse","status":"running","reason":"checking","detail":"running action","elapsed_ms":1200,"timeout_ms":5000}),
            json!({"ts":"2026-06-01T00:00:09Z","hook":"gate-hook","event":"PostToolUse","status":"gate","detail":"gate action"}),
            json!({"ts":"2026-06-01T00:00:10Z","hook":"escalate-hook","event":"PostToolUse","status":"escalate","detail":"escalate action"}),
            json!({"ts":"2026-06-01T00:00:11Z","hook":"correction-hook","event":"PostToolUse","status":"correction","detail":"correction action"}),
            json!({"ts":"2026-06-01T00:00:12Z","hook":"complete-hook","event":"PostToolUse","status":"complete","detail":"complete action"}),
            json!({"ts":"2026-06-01T00:00:13Z","hook":"unknown-hook","event":"PostToolUse","status":"unknown","detail":"unknown action"}),
        ],
    );
    let base = [
        "--log-file",
        log.to_str().unwrap(),
        "--diag-file",
        diag.to_str().unwrap(),
    ];
    let minimal = run(
        &root,
        &[
            "hook-status",
            "--mode",
            "minimal",
            base[0],
            base[1],
            base[2],
            base[3],
        ],
    );
    let (minimal_stdout, minimal_stderr) = output_text(&minimal);
    assert!(minimal.status.success());
    assert!(minimal_stderr.is_empty());
    assert!(minimal_stdout.contains("PostToolUse hook timed out - post-build-check - 2.5s"));
    assert!(minimal_stdout.contains("Last action: cargo test"));
    assert!(minimal_stdout.contains("Safe to interrupt: yes"));
    assert!(!minimal_stdout.contains("[warn]"));

    let focused = run(
        &root,
        &[
            "hook-status",
            "--mode",
            "focused",
            base[0],
            base[1],
            base[2],
            base[3],
        ],
    );
    let (focused_stdout, _) = output_text(&focused);
    assert!(
        focused_stdout.contains("[warn] post-edit-guard PostToolUse(Edit) warn - review - 500ms")
    );
    assert!(focused_stdout.contains("[slow] post-write-guard PostToolUse(Write) slow - 2s"));
    assert!(focused_stdout.contains("[timeout] post-build-check PostToolUse(Bash) timeout"));
    assert!(focused_stdout.contains("[pass] quick-pass PostToolUse(<none>) pass - 100ms"));
    assert!(
        focused_stdout.contains("[skip] explicit-skip PostToolUse(<none>) skipped - not needed")
    );
    assert!(focused_stdout.contains("[block] explicit-block PostToolUse(<none>) block - denied"));
    assert!(
        focused_stdout.contains("[error] hook-failure PostToolUse(<none>) hook_error - failed")
    );
    assert!(
        focused_stdout
            .contains("[running] still-running PostToolUse(<none>) running - checking - 1.2s / 5s")
    );
    for status in ["gate", "escalate", "correction", "complete", "unknown"] {
        assert!(
            focused_stdout.contains(&format!(
                "[info] {status}-hook PostToolUse(<none>) {status}"
            )),
            "missing info label for {status}: {focused_stdout}"
        );
    }
    assert!(!focused_stdout.contains("model_context="));

    let full = run(
        &root,
        &[
            "hook-status",
            "--mode",
            "full",
            base[0],
            base[1],
            base[2],
            base[3],
        ],
    );
    let (full_stdout, _) = output_text(&full);
    assert!(full_stdout.contains("model_context=true"));
    assert!(full_stdout.contains("model_context=false"));
    assert!(full_stdout.contains("last_action=src/lib.rs"));
    assert!(full_stdout.contains("last_action=running action"));
    assert!(full_stdout.contains("last_action=unknown action"));
    assert!(full_stdout.contains(log.to_str().unwrap()));

    let adapter_main = root.join("adapter-main.jsonl");
    let adapter_diag = root.join("adapter-diag.jsonl");
    fs::write(&adapter_main, "").expect("adapter main log should be written");
    write_jsonl(
        &adapter_diag,
        &[
            json!({"ts":"2026-06-01T00:00:00Z","hook":"diag-adapter","event":"PostToolUse","reason":"missing-runner","detail":"adapter action"}),
        ],
    );
    let adapter = run(
        &root,
        &[
            "hook-status",
            "--mode",
            "minimal",
            "--log-file",
            adapter_main.to_str().unwrap(),
            "--diag-file",
            adapter_diag.to_str().unwrap(),
        ],
    );
    let (adapter_stdout, adapter_stderr) = output_text(&adapter);
    assert!(adapter.status.success());
    assert!(adapter_stderr.is_empty());
    assert!(adapter_stdout.contains(
        "PostToolUse hook adapter_error - diag-adapter - missing-runner\nLast action: adapter action"
    ));
    assert!(adapter_stdout.contains(adapter_diag.to_str().unwrap()));

    let empty = root.join("empty.jsonl");
    fs::write(&empty, "").expect("empty fixture should be written");
    let empty_human = run(
        &root,
        &[
            "hook-status",
            "--mode",
            "full",
            "--log-file",
            empty.to_str().unwrap(),
            "--diag-file",
            diag.to_str().unwrap(),
        ],
    );
    let (empty_stdout, empty_stderr) = output_text(&empty_human);
    assert!(empty_human.status.success());
    assert!(empty_stderr.is_empty());
    assert!(empty_stdout.contains("No hook status events found in"));
    let empty_json = json_output(&run(
        &root,
        &[
            "hook-status",
            "--json",
            "--mode",
            "focused",
            "--log-file",
            empty.to_str().unwrap(),
            "--diag-file",
            diag.to_str().unwrap(),
        ],
    ));
    assert_eq!(empty_json["mode"], "focused");
    assert_eq!(
        empty_json["summary"],
        json!({"event":"unknown","total":0,"complete":0,"running":0,"attention":0,"model_context_entries":0})
    );
    assert_eq!(empty_json["entries"], json!([]));
    fs::remove_dir_all(root).expect("fixture should be removed");
}
