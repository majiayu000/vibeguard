use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::json;

fn fixture_log() -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "vibeguard-rule-descriptions-{}-{}.jsonl",
        std::process::id(),
        std::thread::current().name().unwrap_or("test")
    ));
    fs::write(
        &path,
        concat!(
            "{\"ts\":\"2026-06-01T00:00:01Z\",\"session\":\"s1\",",
            "\"hook\":\"count-active-constraints\",\"tool\":\"SessionStart\",",
            "\"decision\":\"warn\",\"reason\":\"constraints=31\",",
            "\"detail\":\"project AGENTS.md=31\",\"client\":\"codex\"}\n",
            "{\"ts\":\"2026-06-01T00:00:02Z\",\"session\":\"s1\",",
            "\"hook\":\"post-edit-guard\",\"tool\":\"Edit\",\"decision\":\"warn\",",
            "\"reason\":\"w14 overlap recent session s2 agent codex\",",
            "\"detail\":\"src/lib.rs\",\"client\":\"codex\"}\n",
            "{\"ts\":\"2026-06-01T00:00:03Z\",\"session\":\"s1\",",
            "\"hook\":\"post-edit-guard\",\"tool\":\"Edit\",\"decision\":\"warn\",",
            "\"reason\":\"w15 shrinking radius 12>8>3\",",
            "\"detail\":\"src/lib.rs\",\"client\":\"codex\"}\n",
            "{\"ts\":\"2026-06-01T00:00:04Z\",\"session\":\"s1\",",
            "\"hook\":\"custom-hook\",\"tool\":\"Edit\",\"decision\":\"warn\",",
            "\"reason\":\"custom policy hit\",\"detail\":\"src/lib.rs\",",
            "\"client\":\"codex\"}\n"
        ),
    )
    .expect("fixture log should be writable");
    path
}

fn observe(command: &str, window_flag: &str, log_path: &Path) -> String {
    let output = Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"))
        .args([
            "observe",
            command,
            window_flag,
            "all",
            "--log-file",
            log_path.to_str().expect("fixture path should be UTF-8"),
        ])
        .output()
        .expect("observe command should run");
    assert!(
        output.status.success(),
        "observe {command} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).expect("observe output should be UTF-8")
}

fn fixture_log_with_reason(reason: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "vibeguard-rule-reason-{}-{}.jsonl",
        std::process::id(),
        std::thread::current().name().unwrap_or("test")
    ));
    let event = json!({
        "ts": "2026-06-01T00:00:01Z",
        "session": "s1",
        "hook": "rust-guard",
        "tool": "Edit",
        "decision": "warn",
        "reason": reason,
        "detail": "src/lib.rs",
        "client": "codex"
    });
    fs::write(&path, format!("{event}\n")).expect("fixture log should be writable");
    path
}

#[test]
fn summary_and_health_translate_rule_reasons_without_hiding_unknown_reasons() {
    let log_path = fixture_log();
    let expected = concat!(
        "U-32: Treat instruction counts as a file-based estimate, not proof of runtime loading, ",
        "semantic conflict, or task failure. ",
        "(constraints=31)"
    );
    let legacy_w14 = concat!(
        "W-14: At most one writable session may operate on a repository; ",
        "parallel helpers must remain read-only."
    );
    let legacy_w15 = concat!(
        "W-15: If the information gain shrinks for three consecutive rounds, ",
        "stop that direction and report it."
    );

    let summary = observe("summary", "--days", &log_path);
    let health = observe("health", "--hours", &log_path);

    assert!(summary.contains(expected), "summary output:\n{summary}");
    assert!(health.contains(expected), "health output:\n{health}");
    assert!(summary.contains(legacy_w14), "summary output:\n{summary}");
    assert!(health.contains(legacy_w14), "health output:\n{health}");
    assert!(summary.contains(legacy_w15), "summary output:\n{summary}");
    assert!(health.contains(legacy_w15), "health output:\n{health}");
    assert!(
        summary.contains("custom policy hit"),
        "summary output:\n{summary}"
    );
    assert!(
        health.contains("custom policy hit"),
        "health output:\n{health}"
    );

    fs::remove_file(log_path).expect("fixture log should be removable");
}

#[test]
fn summary_and_health_translate_nonnumeric_catalog_rule_ids() {
    for (reason, expected) in [
        ("[TASTE-ANSI] hardcoded escape", "TASTE-ANSI: Use a crate"),
        (
            "[TASTE-ASYNC-UNWRAP] async panic",
            "TASTE-ASYNC-UNWRAP: Async code should propagate errors",
        ),
        (
            "[TASTE-PANIC-MSG] missing context",
            "TASTE-PANIC-MSG: `panic!()` or `panic!(\"\")` lacks context.",
        ),
    ] {
        let log_path = fixture_log_with_reason(reason);
        let summary = observe("summary", "--days", &log_path);
        let health = observe("health", "--hours", &log_path);

        assert!(summary.contains(expected), "summary output:\n{summary}");
        assert!(health.contains(expected), "health output:\n{health}");
        fs::remove_file(log_path).expect("fixture log should be removable");
    }
}
