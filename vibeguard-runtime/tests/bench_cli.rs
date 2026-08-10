mod common;

use common::{bin, unique_temp_dir};
use serde_json::Value;
use std::fs;

const FAILURE_CLASSES: [&str; 5] = [
    "hallucinated_edit_target",
    "duplicate_definition",
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
    assert_eq!(report["schema_version"], 2);
    assert_eq!(report["corpus_id"], "builtin-paired-v1");
    assert_eq!(report["production_surface"], "native-runtime-cli");
    assert_eq!(report["runtime_version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(report["provenance_status"], "unverified");
    assert!(report["source_commit"].is_null());
    assert_eq!(report["target"], "unknown-unverified-target");
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
    assert_eq!(report["latency_ms"]["sample_total"], 50);
    assert_eq!(report["latency_ms"]["samples_per_case"], 5);
    assert_eq!(
        report["latency_ms"]["definition"],
        "native runtime command wall time with fresh state per sample"
    );

    for failure_class in FAILURE_CLASSES {
        assert_ne!(
            report["by_class"][failure_class]["positive_decision"],
            "allow"
        );
        assert_eq!(
            report["by_class"][failure_class]["negative_decision"],
            "allow"
        );
        assert_eq!(
            report["by_class"][failure_class]["negative_intercepted"],
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
    assert!(
        stdout.contains("Interception definition: warn or block"),
        "{stdout}"
    );
}

#[test]
fn bench_isolates_stop_checks_from_inherited_ci_bypass_environment() {
    let root = unique_temp_dir("bench-ambient-environment");
    let fake_bin = root.join("fake-bin");
    let sentinel = root.join("ambient-git-ran");
    fs::create_dir_all(&fake_bin).unwrap();
    write_fake_git(&fake_bin, &sentinel);

    let output = bin()
        .args(["bench", "--json"])
        .env("PATH", &fake_bin)
        .env("HOME", root.join("ambient-home"))
        .env("HTTPS_PROXY", "http://proxy.invalid")
        .env("GITHUB_TOKEN", "must-not-reach-benchmark-cases")
        .env("CI", "true")
        .env("GITHUB_ACTIONS", "true")
        .env("TRAVIS", "true")
        .env("CIRCLECI", "true")
        .env("JENKINS_URL", "https://jenkins.invalid")
        .env("GITLAB_CI", "true")
        .env("TF_BUILD", "true")
        .env("VIBEGUARD_SUPPRESS_STOP_VERIFY", "1")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "bench failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["true_positive"], 5);
    assert_eq!(report["false_negative"], 0);
    assert_eq!(report["interception_rate_percent"], 100.0);
    assert!(!sentinel.exists(), "benchmark executed ambient Git shim");
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
fn write_fake_git(directory: &std::path::Path, sentinel: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;

    let executable = directory.join("git");
    fs::write(
        &executable,
        format!(
            "#!/bin/sh\nprintf touched > \"{}\"\nexit 99\n",
            sentinel.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
}

#[cfg(windows)]
fn write_fake_git(directory: &std::path::Path, sentinel: &std::path::Path) {
    fs::write(
        directory.join("git.cmd"),
        format!(
            "@echo touched>\"{}\"\r\n@exit /b 99\r\n",
            sentinel.display()
        ),
    )
    .unwrap();
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
