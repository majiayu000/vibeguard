use super::super::*;
use std::io;

// --- run() integration tests: exercise the full production path via run_inner ---
// These tests verify that run()'s wiring is correct: JSONL parsing, skip-hook filtering,
// session filter, time-window filter, events.len() < 3 early return, metrics file append,
// and LEARN_SUGGESTED stdout output.

fn make_args(dir: &str) -> Vec<String> {
    vec!["sess-A".to_string(), dir.to_string()]
}

fn tmp_dir_for_test(suffix: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("vg-sm-test-{suffix}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn test_run_skip_hooks_reduce_count_below_threshold() {
    // 3 skip-hook events + 2 valid events = 2 valid < 3 → early return, no metrics file.
    let dir = tmp_dir_for_test("skip-hooks");
    let metrics_path = dir.join("session-metrics.jsonl");
    let input = concat!(
        "{\"hook\":\"stop-guard\",\"session\":\"sess-A\"}\n",
        "{\"hook\":\"learn-evaluator\",\"session\":\"sess-A\"}\n",
        "{\"hook\":\"stop-guard\",\"session\":\"sess-A\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
    );
    let mut out = Vec::<u8>::new();
    run_inner(
        &make_args(dir.to_str().unwrap()),
        io::Cursor::new(input),
        &mut out,
        0,
    )
    .unwrap();
    assert!(
        out.is_empty(),
        "no output expected when event count < 3 after skip filtering"
    );
    assert!(
        !metrics_path.exists(),
        "metrics file must not be written when event count < 3"
    );
}

#[test]
fn test_run_session_filter_reduces_count_below_threshold() {
    // 3 events from sess-B (filtered out) + 2 from sess-A = 2 valid < 3 → early return.
    let dir = tmp_dir_for_test("session-filter");
    let metrics_path = dir.join("session-metrics.jsonl");
    let input = concat!(
        "{\"hook\":\"pre-tool\",\"session\":\"sess-B\",\"decision\":\"pass\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-B\",\"decision\":\"pass\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-B\",\"decision\":\"pass\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
    );
    let mut out = Vec::<u8>::new();
    run_inner(
        &make_args(dir.to_str().unwrap()),
        io::Cursor::new(input),
        &mut out,
        0,
    )
    .unwrap();
    assert!(
        out.is_empty(),
        "no output expected when event count < 3 after session filtering"
    );
    assert!(
        !metrics_path.exists(),
        "metrics file must not be written when event count < 3"
    );
}

#[test]
fn test_run_time_filter_reduces_count_below_threshold() {
    // 3 events with ts=epoch (far before cutoff=60s) + 2 with no ts (always pass).
    // Result: 2 valid < 3 → early return.
    let dir = tmp_dir_for_test("time-filter");
    let metrics_path = dir.join("session-metrics.jsonl");
    let input = concat!(
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"ts\":\"1970-01-01T00:00:00Z\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"ts\":\"1970-01-01T00:00:00Z\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"ts\":\"1970-01-01T00:00:00Z\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
    );
    let cutoff = 60u64;
    let mut out = Vec::<u8>::new();
    run_inner(
        &make_args(dir.to_str().unwrap()),
        io::Cursor::new(input),
        &mut out,
        cutoff,
    )
    .unwrap();
    assert!(
        out.is_empty(),
        "no output expected when event count < 3 after time filtering"
    );
    assert!(
        !metrics_path.exists(),
        "metrics file must not be written when event count < 3"
    );
}

#[test]
fn test_run_produces_learn_suggested_and_appends_metrics() {
    // 6 valid events: 4 with warn/block decision (>25%, ≥3 negative) → Signal 1.
    // Verifies: metrics file written, LEARN_SUGGESTED on stdout.
    let dir = tmp_dir_for_test("signals");
    let metrics_path = dir.join("session-metrics.jsonl");
    let input = concat!(
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"warn\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"block\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"warn\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"block\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
    );
    let mut out = Vec::<u8>::new();
    run_inner(
        &make_args(dir.to_str().unwrap()),
        io::Cursor::new(input),
        &mut out,
        0,
    )
    .unwrap();
    let stdout_text = String::from_utf8(out).unwrap();
    assert!(
        stdout_text.contains("LEARN_SUGGESTED"),
        "expected LEARN_SUGGESTED in stdout"
    );
    assert!(
        metrics_path.exists(),
        "metrics file must be written when ≥3 events processed"
    );
    let file_content = std::fs::read_to_string(&metrics_path).unwrap();
    // metrics_path is JSONL; parse the last line to get the entry from this run.
    let last_line = file_content.lines().last().unwrap_or("{}").trim();
    let parsed: serde_json::Value = serde_json::from_str(last_line).unwrap();
    assert_eq!(parsed["session"], "sess-A");
    assert_eq!(parsed["event_count"], 6);
}

#[test]
fn test_run_paralysis_signal_includes_max_depth() {
    let dir = tmp_dir_for_test("paralysis-depth");
    let input = concat!(
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\",\"reason\":\"analysis paralysis 7x\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\",\"reason\":\"analysis paralysis 9x\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\",\"reason\":\"ordinary event\"}\n",
    );
    let mut out = Vec::<u8>::new();
    run_inner(
        &make_args(dir.to_str().unwrap()),
        io::Cursor::new(input),
        &mut out,
        0,
    )
    .unwrap();
    let stdout_text = String::from_utf8(out).unwrap();
    assert!(
        stdout_text.contains("Analysis paralysis: 2 triggers (max depth 9x)"),
        "paralysis signal should include the maximum Nx depth"
    );
}

#[test]
fn test_run_rule_repeat_signal_is_top3_and_deterministic() {
    let dir = tmp_dir_for_test("rule-repeat-top3");
    let mut lines = Vec::new();
    for tag in ["U-02", "U-02", "U-02", "U-02"] {
        lines.push(format!(
                "{{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"warn\",\"reason\":\"[{tag}] repeated\"}}"
            ));
    }
    for tag in [
        "U-01", "U-01", "U-01", "U-03", "U-03", "U-03", "U-04", "U-04", "U-04",
    ] {
        lines.push(format!(
                "{{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"warn\",\"reason\":\"[{tag}] repeated\"}}"
            ));
    }
    let input = lines.join("\n") + "\n";
    let mut out = Vec::<u8>::new();
    run_inner(
        &make_args(dir.to_str().unwrap()),
        io::Cursor::new(input),
        &mut out,
        0,
    )
    .unwrap();
    let stdout_text = String::from_utf8(out).unwrap();
    let u02 = stdout_text.find("Rule [U-02] triggered 4 times").unwrap();
    let u01 = stdout_text.find("Rule [U-01] triggered 3 times").unwrap();
    let u03 = stdout_text.find("Rule [U-03] triggered 3 times").unwrap();
    assert!(
        u02 < u01 && u01 < u03,
        "repeat rules should be sorted by count desc, then rule id asc"
    );
    assert!(
        !stdout_text.contains("Rule [U-04]"),
        "only the top 3 repeated rules should be emitted"
    );
}

#[test]
fn test_run_no_signals_with_all_pass_events() {
    // 5 valid pass events — no warn/block signals → no LEARN_SUGGESTED, but metrics written.
    let dir = tmp_dir_for_test("no-signals");
    let metrics_path = dir.join("session-metrics.jsonl");
    let input = concat!(
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
        "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
    );
    let mut out = Vec::<u8>::new();
    run_inner(
        &make_args(dir.to_str().unwrap()),
        io::Cursor::new(input),
        &mut out,
        0,
    )
    .unwrap();
    let stdout_text = String::from_utf8(out).unwrap();
    assert!(
        !stdout_text.contains("LEARN_SUGGESTED"),
        "no signal expected for clean session"
    );
    assert!(
        metrics_path.exists(),
        "metrics file must still be written even with no signals"
    );
}
