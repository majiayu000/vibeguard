mod common;

use common::bin;
use serde_json::Value;

const FAILURE_CLASSES: [&str; 5] = [
    "invented_api",
    "duplicate_module",
    "swallowed_exception",
    "dangerous_shell_or_git",
    "unverified_done_claim",
];

#[test]
fn bench_json_reports_complete_effectiveness_and_latency_metrics() {
    let output = bin().args(["bench", "--json"]).output().unwrap();
    assert!(
        output.status.success(),
        "bench failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.stderr.is_empty());

    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["schema_version"], 1);
    assert_eq!(report["runtime_version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(report["case_total"], 10);
    assert_eq!(report["positive_total"], 5);
    assert_eq!(report["negative_total"], 5);
    assert_eq!(report["true_positive"], 5);
    assert_eq!(report["false_negative"], 0);
    assert_eq!(report["false_positive"], 0);
    assert_eq!(report["true_negative"], 5);
    assert_eq!(report["interception_rate_percent"], 100.0);
    assert_eq!(report["false_positive_rate_percent"], 0.0);
    assert!(report["latency_ms"]["p50"].as_f64().is_some());
    assert!(report["latency_ms"]["p95"].as_f64().is_some());

    for failure_class in FAILURE_CLASSES {
        assert_eq!(report["by_class"][failure_class]["positive_detected"], true);
        assert_eq!(
            report["by_class"][failure_class]["negative_detected"],
            false
        );
    }
}

#[test]
fn bench_human_output_names_the_three_user_metrics() {
    let output = bin().arg("bench").output().unwrap();
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Interception rate: 100.0%"), "{stdout}");
    assert!(stdout.contains("False-positive rate: 0.0%"), "{stdout}");
    assert!(stdout.contains("Hook latency: p50="), "{stdout}");
    assert!(stdout.contains("Cases: 10"), "{stdout}");
}

#[test]
fn bench_rejects_unknown_options() {
    let output = bin().args(["bench", "--mode=full"]).output().unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("Usage: vibeguard-runtime bench [--json]")
    );
}
