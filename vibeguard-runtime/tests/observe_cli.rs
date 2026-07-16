mod common;

use common::{bin, unique_temp_dir};
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn case_root(label: &str) -> PathBuf {
    let root = unique_temp_dir(&format!("observe_{label}"));
    fs::create_dir_all(root.join("home")).expect("test home should be created");
    root
}

fn cli_for_case(root: &Path) -> Command {
    let mut command = bin();
    command
        .env("HOME", root.join("home"))
        .env("VIBEGUARD_LOG_DIR", root.join("logs"))
        .env_remove("VIBEGUARD_LOG_FILE")
        .current_dir(root);
    command
}

fn run(root: &Path, args: &[&str]) -> Output {
    cli_for_case(root)
        .args(args)
        .output()
        .expect("observe command should run")
}

fn path_text(path: &Path) -> String {
    path.to_str()
        .expect("temporary paths should be UTF-8")
        .to_string()
}

fn write_log(path: &Path, content: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("log parent should be created");
    }
    fs::write(path, content).expect("event log should be written");
}

fn assert_success(output: &Output) {
    assert_eq!(output.status.code(), Some(0));
    assert!(
        output.stderr.is_empty(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn assert_visible_error(output: &Output) {
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).starts_with("vibeguard-runtime error: "));
}

fn output_json(output: &Output) -> Value {
    assert_success(output);
    serde_json::from_slice(&output.stdout).expect("observe output should be JSON")
}

fn assert_empty_observe_json(rendered: &Value, command: &str, log_path: &str) {
    assert_eq!(rendered["command"], command);
    assert_eq!(rendered["source"]["log_path"], log_path);
    assert_eq!(rendered["event_count"], 0);
    assert_eq!(rendered["decision_counts"], json!({}));
    assert_eq!(rendered["hook_counts"], json!({}));
    assert_eq!(rendered["client_distribution"], json!({}));
    assert_eq!(rendered["attention"]["count"], 0);
    assert_eq!(rendered["attention"]["rate"].as_f64(), Some(0.0));
    assert_eq!(rendered["attention"]["percent"].as_f64(), Some(0.0));
    assert_eq!(rendered["top_rule_ids"], json!([]));
    assert_eq!(rendered["top_reason_codes"], json!([]));
    assert_eq!(rendered["duration_stats"]["count"], 0);
    assert_eq!(rendered["duration_stats"]["avg_ms"], 0);
    assert_eq!(rendered["duration_stats"]["min_ms"], Value::Null);
    assert_eq!(rendered["duration_stats"]["p95_ms"], Value::Null);
    assert_eq!(rendered["duration_stats"]["max_ms"], Value::Null);
    assert_eq!(rendered["duration_stats"]["slow_count"], 0);
}

#[test]
fn summary_health_and_session_report_missing_and_empty_data() {
    let root = case_root("no_data");
    let implicit = root.join("logs/events.jsonl");

    let health = run(&root, &["observe", "health", "--scope", "global"]);
    assert_success(&health);
    assert_eq!(
        String::from_utf8_lossy(&health.stdout),
        format!(
            "No log data. Hooks will be automatically logged to {} after being triggered.\n",
            implicit.display()
        )
    );

    let missing_global_json = output_json(&run(
        &root,
        &["observe", "health", "--scope", "global", "--json"],
    ));
    assert_empty_observe_json(&missing_global_json, "health", &path_text(&implicit));
    assert_eq!(missing_global_json["schema_version"], 1);
    assert_eq!(missing_global_json["source"]["scope"], "global");
    assert_eq!(missing_global_json["source"]["period"], "last 24 hours");
    assert_eq!(missing_global_json["source"]["limit"], 5000);
    assert_eq!(missing_global_json["time_range"]["first_ts"], "");
    assert_eq!(missing_global_json["time_range"]["last_ts"], "");
    assert_eq!(missing_global_json["duration_stats"]["slow_ms"], 2000);
    assert_eq!(missing_global_json["attention_states"], json!([]));
    assert_eq!(missing_global_json["diagnostics"], json!([]));

    let summary = run(&root, &["observe", "summary", "--scope", "global"]);
    assert_success(&summary);
    assert_eq!(
        String::from_utf8_lossy(&summary.stdout),
        format!(
            "No log data. Hooks will be automatically logged to {} after being triggered\n",
            implicit.display()
        )
    );

    let empty = root.join("empty.jsonl");
    write_log(&empty, "\n");
    let empty_text = path_text(&empty);
    let health = run(
        &root,
        &[
            "observe",
            "health",
            "--log-file",
            &empty_text,
            "--hours",
            "3",
        ],
    );
    assert_success(&health);
    assert_eq!(
        String::from_utf8_lossy(&health.stdout),
        "No log data for the last 3 hours.\n"
    );
    let summary = run(
        &root,
        &[
            "observe",
            "summary",
            "--log-file",
            &empty_text,
            "--days",
            "2",
        ],
    );
    assert_success(&summary);
    assert_eq!(
        String::from_utf8_lossy(&summary.stdout),
        "No log data for the last 2 days.\n"
    );
    let health_days = run(
        &root,
        &[
            "observe",
            "health",
            "--log-file",
            &empty_text,
            "--days",
            "2",
        ],
    );
    assert_success(&health_days);
    assert_eq!(
        String::from_utf8_lossy(&health_days.stdout),
        "No log data for the last 2 days.\n"
    );

    let health_json = output_json(&run(
        &root,
        &[
            "observe",
            "health",
            "--json",
            "--log-file",
            &empty_text,
            "--hours",
            "all",
        ],
    ));
    assert_empty_observe_json(&health_json, "health", &empty_text);
    assert_eq!(health_json["attention_states"], json!([]));
    assert_eq!(health_json["diagnostics"], json!([]));

    let summary_json = output_json(&run(
        &root,
        &[
            "observe",
            "summary",
            "--json",
            "--log-file",
            &empty_text,
            "--days",
            "all",
        ],
    ));
    assert_empty_observe_json(&summary_json, "summary", &empty_text);

    let health_all = run(
        &root,
        &[
            "observe",
            "health",
            "--log-file",
            &empty_text,
            "--hours",
            "all",
        ],
    );
    assert_success(&health_all);
    assert_eq!(
        String::from_utf8_lossy(&health_all.stdout),
        "No log data.\n"
    );

    let old = root.join("old.jsonl");
    write_log(
        &old,
        "{\"ts\":\"2000-01-01T00:00:00Z\",\"hook\":\"old-hook\",\"decision\":\"warn\"}\n",
    );
    let old_window = run(
        &root,
        &[
            "observe",
            "health",
            "--log-file",
            &path_text(&old),
            "--hours",
            "1",
        ],
    );
    assert_success(&old_window);
    assert_eq!(
        String::from_utf8_lossy(&old_window.stdout),
        "No log data for the last 1 hours.\n"
    );

    let home_log = root.join("home/.vibeguard/events.jsonl");
    write_log(&home_log, "");
    let session = run(
        &root,
        &[
            "observe",
            "session",
            "missing-session",
            "--log-file",
            &path_text(&home_log),
        ],
    );
    assert_success(&session);
    assert_eq!(
        String::from_utf8_lossy(&session.stdout),
        "No observe events found for session missing-session in ~/.vibeguard/events.jsonl.\n"
    );
    fs::remove_dir_all(root).expect("case root should be removed");
}

#[test]
fn explicit_missing_and_directory_inputs_fail_visibly() {
    let root = case_root("input_errors");
    let missing = root.join("missing.jsonl");
    let missing_output = run(
        &root,
        &["observe", "health", "--log-file", &path_text(&missing)],
    );
    assert_visible_error(&missing_output);
    let missing_stderr = String::from_utf8_lossy(&missing_output.stderr);
    assert!(missing_stderr.contains("Log file does not exist:"));
    assert!(missing_stderr.contains(&path_text(&missing)));

    let directory = root.join("events-directory");
    fs::create_dir_all(&directory).expect("input directory should be created");
    let directory_output = run(
        &root,
        &["observe", "health", "--log-file", &path_text(&directory)],
    );
    assert_visible_error(&directory_output);
    fs::remove_dir_all(root).expect("case root should be removed");
}

#[test]
fn malformed_tail_window_and_session_filters_keep_stable_order() {
    let root = case_root("filters");
    let log = root.join("events.jsonl");
    write_log(
        &log,
        concat!(
            "{\"ts\":\"2000-01-01T00:00:00Z\",\"session\":\"s1\",\"hook\":\"old-hook\",\"decision\":\"pass\"}\n",
            "   \n",
            "{\n",
            "null\n",
            "[]\n",
            "{\"ts\":\"2099-01-01T00:00:02Z\",\"session\":\"s1\",\"hook\":\"z-hook\",\"decision\":\"pass\"}\n",
            "{\"ts\":\"2099-01-01T00:00:01Z\",\"session\":\"s2\",\"hook\":\"middle-hook\",\"decision\":\"warn\"}\n",
            "{\"ts\":\"2099-01-01T00:00:02Z\",\"session\":\"s1\",\"hook\":\"a-hook\",\"decision\":\"pass\"}\n",
            "{\"ts\":\"2099-01-01T00:00:01Z\",\"session\":\"s1\",\"hook\":\"b-hook\",\"decision\":\"pass\"}\n"
        ),
    );
    let log_text = path_text(&log);

    let health = output_json(&run(
        &root,
        &[
            "observe",
            "health",
            "--json",
            "--log-file",
            &log_text,
            "--hours",
            "1",
            "--limit",
            "all",
        ],
    ));
    assert_eq!(health["event_count"], 4);
    assert_eq!(health["hook_counts"]["old-hook"], Value::Null);
    assert_eq!(health["time_range"]["first_ts"], "2099-01-01T00:00:01Z");
    assert_eq!(health["time_range"]["last_ts"], "2099-01-01T00:00:02Z");

    let session = output_json(&run(
        &root,
        &[
            "observe",
            "session",
            "s1",
            "--json",
            "--log-file",
            &log_text,
            "--hours",
            "1",
            "--limit",
            "4",
            "--top",
            "10",
        ],
    ));
    assert_eq!(session["event_count"], 3);
    let recent = session["recent_events"].as_array().unwrap();
    assert_eq!(recent.len(), 3);
    assert_eq!(recent[0]["hook"], "b-hook");
    assert_eq!(recent[1]["hook"], "a-hook");
    assert_eq!(recent[2]["hook"], "z-hook");

    let human = run(
        &root,
        &[
            "observe",
            "session",
            "s1",
            "--log-file",
            &log_text,
            "--hours",
            "1",
            "--limit",
            "4",
        ],
    );
    assert_success(&human);
    assert_eq!(
        String::from_utf8_lossy(&human.stdout),
        "VibeGuard observe session s1\nTime range: 2099-01-01T00:00:01Z ~ 2099-01-01T00:00:02Z\nEvents: 3 | Attention: 0 (0.0%)\nTop hooks: a-hook=1, b-hook=1, z-hook=1\n"
    );
    fs::remove_dir_all(root).expect("case root should be removed");
}

#[test]
fn summary_human_and_json_render_deterministic_counts_and_durations() {
    let root = case_root("summary");
    let log = root.join("events.jsonl");
    write_log(
        &log,
        concat!(
            "{\"ts\":\"2099-01-01T00:00:01Z\",\"session\":\"s1\",\"hook\":\"pre-bash-guard\",\"cli\":\"codex\",\"client\":\"codex\",\"decision\":\"pass\",\"duration_ms\":10}\n",
            "{\"ts\":\"2099-01-01T00:00:02Z\",\"session\":\"s1\",\"hook\":\"post-edit-guard\",\"cli\":\"claude\",\"decision\":\"warn\",\"reason\":\"U-16 file too large\",\"detail\":\"src/main.rs\",\"duration_ms\":20}\n",
            "{\"ts\":\"2099-01-01T00:00:03Z\",\"session\":\"s2\",\"hook\":\"pre-bash-guard\",\"cli\":\"codex\",\"client\":\"cursor\",\"decision\":\"block\",\"reason\":\"force push denied\",\"duration_ms\":2500}\n"
        ),
    );
    let log_text = path_text(&log);
    let human = run(
        &root,
        &[
            "observe",
            "summary",
            "--log-file",
            &log_text,
            "--days",
            "all",
        ],
    );
    assert_success(&human);
    let human_text = String::from_utf8_lossy(&human.stdout);
    for expected in [
        "VibeGuard Statistics (all history)",
        "Total triggers: 3 times",
        "Interception (block): 1 times",
        "Warning: 1 times",
        "Pass (pass): 1 times",
        "pre-bash-guard: 2 times",
        "codex: 2 times",
        "1x  force push denied",
        "1x  U-16 file too large",
    ] {
        assert!(
            human_text.contains(expected),
            "missing {expected}:\n{human_text}"
        );
    }

    let rendered = output_json(&run(
        &root,
        &[
            "observe",
            "summary",
            "--json",
            "--log-file",
            &log_text,
            "--days",
            "all",
            "--top",
            "2",
        ],
    ));
    assert_eq!(rendered["schema_version"], 1);
    assert_eq!(rendered["command"], "summary");
    assert_eq!(rendered["source"]["scope"], "project");
    assert_eq!(rendered["event_count"], 3);
    assert_eq!(
        rendered["decision_counts"],
        json!({"block":1,"pass":1,"warn":1})
    );
    assert_eq!(rendered["duration_stats"]["count"], 3);
    assert_eq!(rendered["duration_stats"]["avg_ms"], 843);
    assert_eq!(rendered["duration_stats"]["min_ms"], 10);
    assert_eq!(rendered["duration_stats"]["p95_ms"], 2500);
    assert_eq!(rendered["duration_stats"]["slow_count"], 1);
    assert_eq!(
        rendered["top_rule_ids"][0],
        json!({"value":"U-16","count":1})
    );
    fs::remove_dir_all(root).expect("case root should be removed");
}

#[test]
fn health_human_renders_risk_distributions_unknowns_and_truncation() {
    let root = case_root("health_human");
    let log = root.join("events.jsonl");
    let long_reason = format!("U-16 {}\nsecret", "x".repeat(120));
    let events = [
        json!({"ts":"2099-01-01T00:00:01Z","session":"s1","hook":"alpha","cli":"codex","client":"codex","decision":"pass"}),
        json!({"ts":"2099-01-01T00:00:02Z","session":"s1","hook":"beta","cli":"claude","decision":"warn","reason":long_reason,"detail":"first line\nsecond line"}),
        json!({"ts":"2099-01-01T00:00:03Z","session":"s2","hook":"beta","client":"cursor","decision":"block","reason":"force push denied"}),
        json!({"decision":"warn","reason":"missing metadata"}),
    ];
    write_log(
        &log,
        &events
            .iter()
            .map(|event| serde_json::to_string(event).unwrap())
            .collect::<Vec<_>>()
            .join("\n"),
    );
    let output = run(
        &root,
        &[
            "observe",
            "health",
            "--log-file",
            &path_text(&log),
            "--hours",
            "all",
        ],
    );
    assert_success(&output);
    let text = String::from_utf8_lossy(&output.stdout);
    for expected in [
        "Total triggers: 4",
        "Pass: 1",
        "Risk (non-pass): 3",
        "Risk rate: 75.0%",
        "  block: 1",
        "  warn: 2",
        "  beta: 2",
        "  unknown: 1",
        "detail: first line second line",
    ] {
        assert!(text.contains(expected), "missing {expected}:\n{text}");
    }
    assert!(
        text.contains(
            "CLI distribution:\n  unknown: 2\n  claude: 1\n  codex: 1\nClient distribution:\n  claude: 1\n  codex: 1\n  cursor: 1\n  unknown: 1\n"
        ),
        "{text}"
    );
    assert!(
        text.contains("Risk Hook Top 5:\n  beta: 2\n  unknown: 1\n"),
        "{text}"
    );
    let cleaned = format!("U-16 {} secret", "x".repeat(120));
    let expected_reason = format!("{}...", cleaned.chars().take(97).collect::<String>());
    assert!(
        text.contains(&format!("reason: {expected_reason}")),
        "{text}"
    );
    assert!(
        text.contains("1. 2099-01-01T00:00:03Z | beta | block"),
        "{text}"
    );
    assert!(text.contains("3. ? | unknown | warn"), "{text}");
    fs::remove_dir_all(root).expect("case root should be removed");
}

#[test]
fn health_json_bounds_attention_diagnostics_and_session_events() {
    let root = case_root("health_json");
    let log = root.join("events.jsonl");
    write_log(
        &log,
        concat!(
            "{\"ts\":\"2099-01-01T00:00:01Z\",\"session\":\"s1\",\"hook\":\"slow-hook\",\"decision\":\"pass\",\"duration_ms\":2500}\n",
            "{\"ts\":\"2099-01-01T00:00:02Z\",\"session\":\"s1\",\"hook\":\"warn-hook\",\"decision\":\"warn\",\"reason\":\"U-16 warning\",\"duration_ms\":20}\n",
            "{\"ts\":\"2099-01-01T00:00:03Z\",\"session\":\"s1\",\"hook\":\"timeout-hook\",\"decision\":\"warn\",\"status\":\"timeout\",\"reason\":\"hook timeout\",\"duration_ms\":30000}\n",
            "{\"ts\":\"2099-01-01T00:00:04Z\",\"session\":\"s1\",\"hook\":\"block-hook\",\"decision\":\"block\",\"duration_ms\":5}\n"
        ),
    );
    let log_text = path_text(&log);
    let health = output_json(&run(
        &root,
        &[
            "observe",
            "health",
            "--json",
            "--log-file",
            &log_text,
            "--hours",
            "all",
            "--top",
            "1",
        ],
    ));
    assert_eq!(health["command"], "health");
    assert_eq!(health["event_count"], 4);
    assert_eq!(health["attention"]["count"], 4);
    assert_eq!(health["attention_states"].as_array().unwrap().len(), 1);
    assert_eq!(health["attention_states"][0]["hook"], "block-hook");
    assert_eq!(health["diagnostics"].as_array().unwrap().len(), 1);
    assert_eq!(health["diagnostics"][0]["hook"], "timeout-hook");
    assert_eq!(health["diagnostics"][0]["diagnostic"], "timeout");
    assert_eq!(health["duration_stats"]["count"], 4);
    assert_eq!(health["duration_stats"]["avg_ms"], 8131);
    assert_eq!(health["duration_stats"]["slow_count"], 2);

    let session = output_json(&run(
        &root,
        &[
            "observe",
            "session",
            "s1",
            "--json",
            "--log-file",
            &log_text,
            "--top",
            "2",
        ],
    ));
    assert_eq!(session["recent_events"].as_array().unwrap().len(), 2);
    assert_eq!(session["recent_events"][0]["hook"], "timeout-hook");
    assert_eq!(session["recent_events"][1]["hook"], "block-hook");
    assert_eq!(session["attention_states"].as_array().unwrap().len(), 2);
    assert_eq!(session["diagnostics"].as_array().unwrap().len(), 2);
    fs::remove_dir_all(root).expect("case root should be removed");
}

#[test]
fn prometheus_output_directory_and_parent_file_fail_visibly() {
    let root = case_root("output_errors");
    let input = root.join("events.jsonl");
    write_log(
        &input,
        "{\"hook\":\"pre-bash-guard\",\"decision\":\"pass\"}\n",
    );
    let output_directory = root.join("metrics-directory");
    fs::create_dir_all(&output_directory).expect("output directory should be created");

    let directory_failure = run(
        &root,
        &[
            "observe",
            "export",
            "prometheus",
            "--since",
            "all",
            "--input-file",
            &path_text(&input),
            "--file",
            &path_text(&output_directory),
        ],
    );
    assert_visible_error(&directory_failure);
    assert!(output_directory.is_dir());

    let parent_file = root.join("parent-file");
    fs::write(&parent_file, "not a directory").expect("parent file should be written");
    let nested_output = parent_file.join("metrics.prom");
    let parent_failure = run(
        &root,
        &[
            "observe",
            "export",
            "prometheus",
            "--since",
            "all",
            "--input-file",
            &path_text(&input),
            "--file",
            &path_text(&nested_output),
        ],
    );
    assert_visible_error(&parent_failure);
    assert!(!nested_output.exists());
    fs::remove_dir_all(root).expect("case root should be removed");
}
