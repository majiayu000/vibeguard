mod common;

use common::{bin, path_text, unique_temp_dir};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Output;

fn case_root(label: &str) -> PathBuf {
    let root = unique_temp_dir(&format!("observe_value_{label}"));
    fs::create_dir_all(root.join("home")).expect("test home should be created");
    root
}

fn run(root: &Path, args: &[&str]) -> Output {
    let mut command = bin();
    command
        .env("HOME", root.join("home"))
        .env("VIBEGUARD_LOG_DIR", root.join("logs"))
        .env_remove("VIBEGUARD_LOG_FILE")
        .current_dir(root);
    command
        .args(args)
        .output()
        .expect("observe value command should run")
}

fn write_value_log(path: &Path, content: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("log parent should be created");
    }
    fs::write(path, content).expect("event log should be written");
}

fn output_json(output: &Output) -> Value {
    assert_eq!(
        output.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("observe value output should be JSON")
}

fn assert_success(output: &Output) {
    assert_eq!(
        output.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.stderr.is_empty());
}

#[test]
fn value_json_reports_observed_follow_up_without_verified_build_evidence() {
    let root = case_root("generic_follow_up");
    let log = root.join("events.jsonl");
    write_value_log(
        &log,
        concat!(
            "{\"ts\":\"2099-01-01T00:00:01Z\",\"session\":\"session-a\",\"hook\":\"post-edit-guard\",\"decision\":\"warn\",\"reason\":\"U-16 warning\"}\n",
            "{\"ts\":\"2099-01-01T00:00:02Z\",\"session\":\"session-a\",\"hook\":\"post-edit-guard\",\"decision\":\"pass\",\"duration_ms\":12}\n"
        ),
    );

    let rendered = output_json(&run(
        &root,
        &[
            "observe",
            "value",
            "--json",
            "--days",
            "all",
            "--log-file",
            &path_text(&log),
        ],
    ));

    assert_eq!(rendered["command"], "value");
    assert_eq!(rendered["value"]["data_state"], "observed");
    assert_eq!(rendered["value"]["observed"]["attention_events"], 1);
    assert_eq!(
        rendered["value"]["observed"]["sessions_with_later_follow_up_pass"],
        1
    );
    assert_eq!(
        rendered["value"]["verified"]["sessions_with_later_build_pass"],
        0
    );
    assert_eq!(rendered["value"]["estimated"]["available"], false);

    fs::remove_dir_all(root).expect("case root should be removed");
}

#[test]
fn value_json_applies_attention_and_correlation_boundaries() {
    let root = case_root("boundaries");
    let log = root.join("events.jsonl");
    write_value_log(
        &log,
        concat!(
            "{\"ts\":\"2099-01-01T00:00:01Z\",\"session\":\"s1\",\"hook\":\"post-edit-guard\",\"decision\":\"warn\",\"reason\":\"warning\",\"duration_ms\":10}\n",
            "{\"ts\":\"2099-01-01T00:00:02Z\",\"session\":\"s1\",\"hook\":\"post-edit-guard\",\"decision\":\"pass\",\"duration_ms\":11}\n",
            "{\"ts\":\"2099-01-01T00:00:03Z\",\"session\":\"s2\",\"hook\":\"pre-write-guard\",\"decision\":\"block\",\"duration_ms\":20}\n",
            "{\"ts\":\"2099-01-01T00:00:04Z\",\"session\":\"s2\",\"hook\":\"post-build-check\",\"decision\":\"pass\",\"elapsed_ms\":\"21\"}\n",
            "{\"ts\":\"2099-01-01T00:00:05Z\",\"session\":\"s3\",\"hook\":\"pre-edit-guard\",\"status\":\"gate\",\"decision\":\"gate\"}\n",
            "{\"ts\":\"2099-01-01T00:00:06Z\",\"session\":\"s3\",\"hook\":\"post-edit-guard\",\"status\":\"skipped\",\"decision\":\"pass\",\"reason\":\"suppressed by cooldown\",\"duration_ms\":30}\n",
            "{\"ts\":\"2099-01-01T00:00:07Z\",\"session\":\"s4\",\"hook\":\"pre-bash-guard\",\"status\":\"escalate\",\"decision\":\"escalate\"}\n",
            "{\"ts\":\"2099-01-01T00:00:07Z\",\"session\":\"s4\",\"hook\":\"post-edit-guard\",\"decision\":\"pass\",\"duration_ms\":40}\n",
            "{\"ts\":\"not-a-timestamp\",\"session\":\"s5\",\"hook\":\"post-edit-guard\",\"status\":\"correction\",\"decision\":\"correction\"}\n",
            "{\"ts\":\"2099-01-01T00:00:10Z\",\"session\":\"s5\",\"hook\":\"post-edit-guard\",\"decision\":\"pass\"}\n",
            "{\"ts\":\"2099-01-01T00:00:11Z\",\"session\":\"\",\"hook\":\"post-edit-guard\",\"status\":\"correction\",\"decision\":\"correction\"}\n",
            "{\"ts\":\"not-a-timestamp\",\"session\":\"\",\"hook\":\"post-edit-guard\",\"status\":\"warn\",\"decision\":\"warn\"}\n",
            "{\"ts\":\"2099-01-01T00:00:12Z\",\"session\":\"s6\",\"decision\":\"warn\"}\n",
            "{\"ts\":\"2099-01-01T00:00:13Z\",\"session\":\"s6\",\"decision\":\"correction\"}\n",
            "{\"ts\":\"2099-01-01T00:00:14Z\",\"session\":\"s8\",\"status\":\"slow\",\"decision\":\"pass\",\"duration_ms\":2500}\n",
            "{\"ts\":\"2099-01-01T00:00:15Z\",\"session\":\"s9\",\"status\":\"timeout\",\"decision\":\"warn\"}\n",
            "{\"ts\":\"2099-01-01T00:00:16Z\",\"session\":\"s7\",\"status\":\"pass\",\"decision\":\"pass\",\"reason\":\"suppressed text without skipped status\"}\n"
        ),
    );

    let rendered = output_json(&run(
        &root,
        &[
            "observe",
            "value",
            "--json",
            "--days",
            "all",
            "--log-file",
            &path_text(&log),
        ],
    ));
    let value = &rendered["value"];
    let observed = &value["observed"];

    assert_eq!(value["data_state"], "observed");
    assert_eq!(observed["attention_events"], 9);
    assert_eq!(observed["sessions_with_attention"], 6);
    assert_eq!(observed["sessions_with_later_follow_up_pass"], 2);
    assert_eq!(observed["sessions_without_later_follow_up_pass"], 4);
    assert_eq!(observed["sessions_with_repeated_attention"], 1);
    assert_eq!(observed["uncorrelatable_attention_events"], 3);
    assert_eq!(observed["suppression_events"], 1);
    assert_eq!(
        observed["hook_duration_ms"],
        serde_json::json!({
            "count": 7,
            "total_ms": 2632,
            "avg_ms": 376,
            "p95_ms": 2500
        })
    );
    assert_eq!(value["verified"]["sessions_with_later_build_pass"], 1);
    assert_eq!(value["estimated"]["available"], false);
    assert!(
        value["estimated"]["reason"]
            .as_str()
            .unwrap()
            .contains("causal")
    );
    assert!(value["limitations"].as_array().unwrap().iter().any(|item| {
        item.as_str()
            .is_some_and(|text| text.contains("not proof VibeGuard caused"))
    }));

    fs::remove_dir_all(root).expect("case root should be removed");
}

#[test]
fn value_human_output_leads_with_boundary_and_has_no_success_headline() {
    let root = case_root("human");
    let log = root.join("events.jsonl");
    write_value_log(
        &log,
        "{\"ts\":\"2099-01-01T00:00:01Z\",\"session\":\"s1\",\"decision\":\"warn\"}\n",
    );

    let output = run(
        &root,
        &[
            "observe",
            "value",
            "--days",
            "all",
            "--log-file",
            &path_text(&log),
        ],
    );
    assert_success(&output);
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.starts_with("Evidence boundary:"), "{text}");
    assert!(text.contains("Verified\n"), "{text}");
    assert!(text.contains("Observed\n"), "{text}");
    assert!(text.contains("Estimated/unavailable\n"), "{text}");
    assert!(text.contains("Data state: observed"), "{text}");
    assert!(!text.to_ascii_lowercase().contains("zero risk"), "{text}");
    assert!(!text.to_ascii_lowercase().contains("success"), "{text}");

    fs::remove_dir_all(root).expect("case root should be removed");
}

#[test]
fn value_distinguishes_missing_empty_and_no_events_in_window() {
    let missing_root = case_root("missing");
    let missing_json = output_json(&run(&missing_root, &["observe", "value", "--json"]));
    assert_eq!(missing_json["value"]["data_state"], "missing");
    let missing_human = run(&missing_root, &["observe", "value"]);
    assert_success(&missing_human);
    let missing_text = String::from_utf8_lossy(&missing_human.stdout);
    assert!(
        missing_text.contains("Data state: missing"),
        "{missing_text}"
    );
    assert!(!missing_text.to_ascii_lowercase().contains("zero risk"));
    assert!(!missing_text.to_ascii_lowercase().contains("success"));
    fs::remove_dir_all(missing_root).expect("missing case root should be removed");

    let empty_root = case_root("empty");
    let empty_log = empty_root.join("empty.jsonl");
    write_value_log(&empty_log, "\n");
    let empty_json = output_json(&run(
        &empty_root,
        &[
            "observe",
            "value",
            "--json",
            "--days",
            "all",
            "--log-file",
            &path_text(&empty_log),
        ],
    ));
    assert_eq!(empty_json["value"]["data_state"], "empty");
    fs::remove_dir_all(empty_root).expect("empty case root should be removed");

    let window_root = case_root("window");
    let old_log = window_root.join("old.jsonl");
    write_value_log(
        &old_log,
        "{\"ts\":\"2000-01-01T00:00:00Z\",\"session\":\"old\",\"decision\":\"warn\"}\n",
    );
    let window_json = output_json(&run(
        &window_root,
        &[
            "observe",
            "value",
            "--json",
            "--days",
            "7",
            "--log-file",
            &path_text(&old_log),
        ],
    ));
    assert_eq!(window_json["value"]["data_state"], "empty");
    fs::remove_dir_all(window_root).expect("window case root should be removed");
}

#[test]
fn value_rejects_bad_explicit_inputs_and_help_lists_the_command() {
    let root = case_root("input_errors");
    let missing = root.join("missing.jsonl");
    let missing_output = run(
        &root,
        &[
            "observe",
            "value",
            "--json",
            "--log-file",
            &path_text(&missing),
        ],
    );
    assert_eq!(missing_output.status.code(), Some(1));
    assert!(missing_output.stdout.is_empty());
    let missing_stderr = String::from_utf8_lossy(&missing_output.stderr);
    assert!(missing_stderr.starts_with("vibeguard-runtime error: "));
    assert!(missing_stderr.contains("Log file does not exist:"));

    let malformed_window = run(&root, &["observe", "value", "--days", "not-a-window"]);
    assert_eq!(malformed_window.status.code(), Some(1));
    assert!(malformed_window.stdout.is_empty());
    assert!(
        String::from_utf8_lossy(&malformed_window.stderr).starts_with("vibeguard-runtime error: ")
    );

    let help = run(&root, &["observe", "--help"]);
    assert_eq!(help.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&help.stderr).contains("value"));

    let main_help = run(&root, &[]);
    assert_eq!(main_help.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&main_help.stderr)
            .contains("<summary|health|session|value|export prometheus>")
    );
    fs::remove_dir_all(root).expect("input error case root should be removed");
}

#[test]
fn value_json_supports_global_scope_and_seven_day_default() {
    let root = case_root("scope");
    let log = root.join("events.jsonl");
    write_value_log(&log, "\n");
    let rendered = output_json(&run(
        &root,
        &[
            "observe",
            "value",
            "--json",
            "--scope",
            "global",
            "--log-file",
            &path_text(&log),
        ],
    ));
    assert_eq!(rendered["source"]["scope"], "global");
    assert_eq!(rendered["source"]["period"], "last 7 days");
    fs::remove_dir_all(root).expect("scope case root should be removed");
}

#[test]
fn value_limitations_describe_limit_before_time_window() {
    let root = case_root("limit_boundary");
    let log = root.join("events.jsonl");
    write_value_log(&log, "\n");

    let bounded = output_json(&run(
        &root,
        &["observe", "value", "--json", "--log-file", &path_text(&log)],
    ));
    let bounded_limitation = "Counts consider at most the configured 5000 most-recent parsed events from the selected scope, then apply the selected time window; earlier parsed events and events outside it are not considered.";
    assert!(
        bounded["value"]["limitations"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item == bounded_limitation)
    );
    let bounded_human = run(&root, &["observe", "value", "--log-file", &path_text(&log)]);
    assert_success(&bounded_human);
    assert!(String::from_utf8_lossy(&bounded_human.stdout).contains(bounded_limitation));

    let all = output_json(&run(
        &root,
        &[
            "observe",
            "value",
            "--json",
            "--limit",
            "all",
            "--log-file",
            &path_text(&log),
        ],
    ));
    let all_limitation = "Because --limit all was explicitly requested, counts consider all parsed events from the selected scope, then apply the selected time window; events outside it are not considered.";
    assert!(
        all["value"]["limitations"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item == all_limitation)
    );
    let all_human = run(
        &root,
        &[
            "observe",
            "value",
            "--limit",
            "all",
            "--log-file",
            &path_text(&log),
        ],
    );
    assert_success(&all_human);
    assert!(String::from_utf8_lossy(&all_human.stdout).contains(all_limitation));

    fs::remove_dir_all(root).expect("limit boundary case root should be removed");
}

#[test]
fn rendered_event_json_preserves_record_ids_and_legacy_empty_values() {
    let root = case_root("record_ids");
    let log = root.join("events.jsonl");
    write_value_log(
        &log,
        concat!(
            "{\"ts\":\"2099-01-01T00:00:01Z\",\"session\":\"s1\",\"hook\":\"warn-hook\",\"decision\":\"warn\",\"record_id\":\"VGR-1-2-3\"}\n",
            "{\"ts\":\"2099-01-01T00:00:02Z\",\"session\":\"s1\",\"hook\":\"pass-hook\",\"decision\":\"pass\"}\n"
        ),
    );
    let rendered = output_json(&run(
        &root,
        &[
            "observe",
            "health",
            "--json",
            "--hours",
            "all",
            "--top",
            "10",
            "--log-file",
            &path_text(&log),
        ],
    ));
    let events = rendered["attention_states"].as_array().unwrap();
    assert_eq!(events[0]["record_id"], "VGR-1-2-3");
    assert!(events[0]["record_id"].is_string());
    assert!(rendered["recent_events"].as_array().is_none());

    let session = output_json(&run(
        &root,
        &[
            "observe",
            "session",
            "s1",
            "--json",
            "--hours",
            "all",
            "--top",
            "10",
            "--log-file",
            &path_text(&log),
        ],
    ));
    let recent = session["recent_events"].as_array().unwrap();
    assert_eq!(recent.len(), 2);
    assert_eq!(recent[0]["record_id"], "VGR-1-2-3");
    assert_eq!(recent[1]["record_id"], "");
    assert!(recent[1]["record_id"].is_string());
    fs::remove_dir_all(root).expect("record id case root should be removed");
}

#[test]
fn old_summary_has_no_compliance_or_token_savings_proxy() {
    let root = case_root("old_summary");
    let log = root.join("events.jsonl");
    write_value_log(
        &log,
        concat!(
            "{\"ts\":\"2099-01-01T00:00:01Z\",\"session\":\"s1\",\"hook\":\"warn-hook\",\"decision\":\"warn\"}\n",
            "{\"ts\":\"2099-01-01T00:00:02Z\",\"session\":\"s1\",\"hook\":\"pass-hook\",\"decision\":\"pass\"}\n"
        ),
    );
    let output = run(
        &root,
        &[
            "observe",
            "summary",
            "--days",
            "all",
            "--log-file",
            &path_text(&log),
        ],
    );
    assert_success(&output);
    let text = String::from_utf8_lossy(&output.stdout).to_ascii_lowercase();
    assert!(!text.contains("compliance"), "{text}");
    assert!(!text.contains("token savings"), "{text}");
    assert!(!text.contains("estimated savings"), "{text}");
    fs::remove_dir_all(root).expect("summary case root should be removed");
}

#[test]
fn value_hook_duration_total_saturates() {
    let root = case_root("duration_overflow");
    let log = root.join("events.jsonl");
    write_value_log(
        &log,
        concat!(
            "{\"ts\":\"2099-01-01T00:00:01Z\",\"session\":\"s1\",\"decision\":\"pass\",\"duration_ms\":18446744073709551615}\n",
            "{\"ts\":\"2099-01-01T00:00:02Z\",\"session\":\"s1\",\"decision\":\"pass\",\"duration_ms\":1}\n"
        ),
    );
    let rendered = output_json(&run(
        &root,
        &[
            "observe",
            "value",
            "--json",
            "--days",
            "all",
            "--log-file",
            &path_text(&log),
        ],
    ));
    assert_eq!(
        rendered["value"]["observed"]["hook_duration_ms"],
        serde_json::json!({
            "count": 2,
            "total_ms": 18446744073709551615u64,
            "avg_ms": 9223372036854775807u64,
            "p95_ms": 18446744073709551615u64
        })
    );
    fs::remove_dir_all(root).expect("duration case root should be removed");
}
