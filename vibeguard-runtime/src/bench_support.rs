use serde_json::{Map, Value, json};
use std::env;
use std::ffi::OsStr;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::OnceLock;
use std::time::Instant;

pub(super) type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;

const CORPUS_ID: &str = "builtin-paired-v1";
const LATENCY_SAMPLES_PER_CASE: usize = 5;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Decision {
    Allow,
    Warn,
    Block,
}

impl Decision {
    fn intercepted(self) -> bool {
        self != Self::Allow
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Allow => "allow",
            Self::Warn => "warn",
            Self::Block => "block",
        }
    }
}

#[derive(Debug)]
pub(super) struct CaseResult {
    failure_class: &'static str,
    positive: bool,
    decision: Decision,
    latencies_ms: Vec<f64>,
}

pub(super) fn measured_case(
    failure_class: &'static str,
    positive: bool,
    mut prepare: impl FnMut() -> Result,
    mut operation: impl FnMut() -> Result<Decision>,
) -> Result<CaseResult> {
    prepare()?;
    let expected = operation()?;
    let mut latencies_ms = Vec::with_capacity(LATENCY_SAMPLES_PER_CASE);
    for _ in 0..LATENCY_SAMPLES_PER_CASE {
        prepare()?;
        let started = Instant::now();
        let decision = operation()?;
        if decision != expected {
            return Err(format!(
                "benchmark decision changed between samples for {failure_class}: {} then {}",
                expected.as_str(),
                decision.as_str()
            )
            .into());
        }
        latencies_ms.push(started.elapsed().as_secs_f64() * 1000.0);
    }
    Ok(CaseResult {
        failure_class,
        positive,
        decision: expected,
        latencies_ms,
    })
}

pub(super) fn run_runtime(
    runtime: &Path,
    args: &[&str],
    input: &str,
    root: &Path,
) -> Result<Output> {
    let git = trusted_git_executable()?;
    let git_parent = git
        .parent()
        .ok_or_else(|| format!("benchmark Git path has no parent: {}", git.display()))?;
    let mut child = Command::new(runtime);
    child
        .args(args.iter().map(OsStr::new))
        .current_dir(root)
        .env_clear()
        .env("PATH", git_parent)
        .env("HOME", root.join("home"))
        .env("USERPROFILE", root.join("home"))
        .env("TMPDIR", root.join("tmp"))
        .env("TMP", root.join("tmp"))
        .env("TEMP", root.join("tmp"))
        .env("LC_ALL", "C")
        .env("VIBEGUARD_GIT_EXECUTABLE", &git)
        .env("VIBEGUARD_PRE_EDIT_SUGGEST", "0")
        .env("VIBEGUARD_PROJECT_HASH", "bench-project")
        .env("VIBEGUARD_SESSION_ID", "bench-session")
        .env("VIBEGUARD_LOG_DIR", root.join("logs"))
        .env(
            "VIBEGUARD_PROJECT_LOG_DIR",
            root.join("logs/projects/bench-project"),
        )
        .env(
            "VIBEGUARD_LOG_FILE",
            root.join("logs/projects/bench-project/events.jsonl"),
        );
    copy_required_windows_environment(&mut child);
    let mut child = child
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    child
        .stdin
        .as_mut()
        .ok_or("benchmark child stdin unavailable")?
        .write_all(input.as_bytes())?;
    Ok(child.wait_with_output()?)
}

#[cfg(windows)]
fn copy_required_windows_environment(command: &mut Command) {
    for name in ["SYSTEMROOT", "WINDIR"] {
        if let Some(value) = env::var_os(name) {
            command.env(name, value);
        }
    }
}

#[cfg(not(windows))]
fn copy_required_windows_environment(_: &mut Command) {}

fn trusted_git_executable() -> Result<PathBuf> {
    static GIT: OnceLock<Option<PathBuf>> = OnceLock::new();
    GIT.get_or_init(find_trusted_git)
        .clone()
        .ok_or_else(|| "benchmark requires a trusted Git executable in a standard location".into())
}

fn find_trusted_git() -> Option<PathBuf> {
    let mut candidates = vec![
        PathBuf::from("/usr/bin/git"),
        PathBuf::from("/usr/local/bin/git"),
        PathBuf::from("/opt/homebrew/bin/git"),
    ];
    for variable in ["ProgramFiles", "ProgramFiles(x86)"] {
        if let Some(root) = env::var_os(variable) {
            candidates.push(PathBuf::from(&root).join("Git/cmd/git.exe"));
            candidates.push(PathBuf::from(root).join("Git/bin/git.exe"));
        }
    }
    candidates
        .into_iter()
        .find(|candidate| candidate.is_file())
        .and_then(|candidate| candidate.canonicalize().ok())
}

pub(super) fn require_success(output: &Output, label: &str) -> Result {
    if output.status.success() {
        return Ok(());
    }
    Err(format!(
        "{label} failed with {}: {}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    )
    .into())
}

pub(super) fn post_write_decision(output: &Output) -> Result<Decision> {
    require_success(output, "post-write benchmark")?;
    let stdout = String::from_utf8(output.stdout.clone())?;
    if stdout.trim().is_empty() {
        return Ok(Decision::Allow);
    }
    let payload: Value = serde_json::from_str(&stdout)?;
    let context = payload
        .pointer("/hookSpecificOutput/additionalContext")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or("post-write benchmark returned unknown warning output")?;
    let _ = context;
    Ok(Decision::Warn)
}

pub(super) fn path_str(path: &Path) -> Result<&str> {
    path.to_str()
        .ok_or_else(|| format!("benchmark path is not UTF-8: {}", path.display()).into())
}

pub(super) fn build_report(cases: &[CaseResult]) -> Value {
    let positive_total = cases.iter().filter(|case| case.positive).count();
    let negative_total = cases.len().saturating_sub(positive_total);
    let true_positive = cases
        .iter()
        .filter(|case| case.positive && case.decision.intercepted())
        .count();
    let false_positive = cases
        .iter()
        .filter(|case| !case.positive && case.decision.intercepted())
        .count();
    let mut by_class = Map::new();
    for case in cases {
        let entry = by_class
            .entry(case.failure_class.to_string())
            .or_insert_with(|| json!({}));
        let prefix = if case.positive {
            "positive"
        } else {
            "negative"
        };
        entry[format!("{prefix}_decision")] = json!(case.decision.as_str());
        entry[format!("{prefix}_intercepted")] = json!(case.decision.intercepted());
    }
    let latencies = cases
        .iter()
        .flat_map(|case| case.latencies_ms.iter().copied())
        .collect::<Vec<_>>();
    let source_commit = option_env!("CARGO_VIBEGUARD_BUILD_COMMIT");
    let build_target = option_env!("CARGO_VIBEGUARD_BUILD_TARGET");
    let provenance_status = if !cfg!(debug_assertions)
        && source_commit.is_some_and(valid_git_commit)
        && build_target.is_some_and(|target| !target.trim().is_empty())
    {
        "embedded-release-build"
    } else {
        "unverified"
    };
    json!({
        "schema_version": 2,
        "corpus_id": CORPUS_ID,
        "build_kind": if cfg!(debug_assertions) { "development" } else { "release" },
        "provenance_status": provenance_status,
        "source_commit": source_commit,
        "target": build_target.unwrap_or("unknown-unverified-target"),
        "production_surface": "native-runtime-cli",
        "runtime_version": env!("CARGO_PKG_VERSION"),
        "case_total": cases.len(),
        "positive_total": positive_total,
        "negative_total": negative_total,
        "true_positive": true_positive,
        "false_negative": positive_total.saturating_sub(true_positive),
        "false_positive": false_positive,
        "true_negative": negative_total.saturating_sub(false_positive),
        "interception_rate_percent": percentage(true_positive, positive_total),
        "false_positive_rate_percent": percentage(false_positive, negative_total),
        "latency_ms": {
            "definition": "native runtime command wall time with fresh state per sample",
            "sample_total": latencies.len(),
            "samples_per_case": LATENCY_SAMPLES_PER_CASE,
            "p50": percentile(&latencies, 50),
            "p95": percentile(&latencies, 95)
        },
        "by_class": by_class
    })
}

fn valid_git_commit(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn percentage(numerator: usize, denominator: usize) -> f64 {
    if denominator == 0 {
        return 0.0;
    }
    (numerator as f64 / denominator as f64 * 1000.0).round() / 10.0
}

fn percentile(values: &[f64], percentile: usize) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let rank = (percentile * sorted.len()).div_ceil(100).max(1);
    (sorted[rank - 1] * 1000.0).round() / 1000.0
}

pub(super) fn render_benchmark_human(report: &Value) -> Result {
    let number = |field: &str| {
        report[field]
            .as_f64()
            .ok_or_else(|| format!("benchmark report field is not numeric: {field}"))
    };
    let case_total = report["case_total"]
        .as_u64()
        .ok_or("benchmark case_total is not an integer")?;
    let p50 = report["latency_ms"]["p50"]
        .as_f64()
        .ok_or("benchmark p50 is not numeric")?;
    let p95 = report["latency_ms"]["p95"]
        .as_f64()
        .ok_or("benchmark p95 is not numeric")?;
    println!("VibeGuard benchmark {}", env!("CARGO_PKG_VERSION"));
    println!("Cases: {case_total}");
    println!("Interception definition: warn or block");
    println!(
        "Interception rate: {:.1}%",
        number("interception_rate_percent")?
    );
    println!(
        "False-positive rate: {:.1}%",
        number("false_positive_rate_percent")?
    );
    println!("Hook latency: p50={p50:.3}ms p95={p95:.3}ms");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn nearest_rank_percentiles_are_deterministic() {
        let values = [5.0, 1.0, 4.0, 2.0, 3.0];
        assert_eq!(percentile(&values, 50), 3.0);
        assert_eq!(percentile(&values, 95), 5.0);
    }

    #[test]
    fn percentage_rounds_to_one_decimal_place() {
        assert_eq!(percentage(2, 3), 66.7);
        assert_eq!(percentage(0, 0), 0.0);
    }

    #[test]
    fn commit_validation_requires_full_hex_sha() {
        assert!(valid_git_commit("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
        assert!(!valid_git_commit("abc123"));
        assert!(!valid_git_commit(
            "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
        ));
    }

    #[test]
    fn structured_post_write_output_counts_every_warning() {
        let output = Output {
            status: success_status(),
            stdout: br#"{"hookSpecificOutput":{"additionalContext":"[OTHER] warning"}}"#.to_vec(),
            stderr: Vec::new(),
        };
        assert_eq!(post_write_decision(&output).unwrap(), Decision::Warn);
    }

    #[test]
    fn every_warmup_and_timed_sample_gets_fresh_preparation() {
        let prepared = Cell::new(0);
        let observed = Cell::new(0);
        let result = measured_case(
            "fresh-state",
            false,
            || {
                prepared.set(prepared.get() + 1);
                Ok(())
            },
            || {
                assert_eq!(prepared.get(), observed.get() + 1);
                observed.set(observed.get() + 1);
                Ok(Decision::Allow)
            },
        )
        .unwrap();
        assert_eq!(prepared.get(), LATENCY_SAMPLES_PER_CASE + 1);
        assert_eq!(observed.get(), LATENCY_SAMPLES_PER_CASE + 1);
        assert_eq!(result.latencies_ms.len(), LATENCY_SAMPLES_PER_CASE);
    }

    #[cfg(unix)]
    fn success_status() -> std::process::ExitStatus {
        use std::os::unix::process::ExitStatusExt;
        std::process::ExitStatus::from_raw(0)
    }

    #[cfg(windows)]
    fn success_status() -> std::process::ExitStatus {
        use std::os::windows::process::ExitStatusExt;
        std::process::ExitStatus::from_raw(0)
    }
}
