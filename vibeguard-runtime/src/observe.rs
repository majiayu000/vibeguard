use serde_json::Value;
use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::{self, BufRead, Read};
use std::path::{Path, PathBuf};

use crate::event_schema::{UNKNOWN, decision, field};
use crate::log_scope::{LogScope, LogScopeOptions, parse_scope, resolve_log_file};
use crate::time_utils;

type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;

const DEFAULT_SINCE_SECS: u64 = 7 * 24 * 60 * 60;
const KNOWN_EXTS: &[&str] = &[
    "rs", "py", "ts", "js", "mjs", "cjs", "tsx", "jsx", "go", "java", "kt", "swift", "rb", "sh",
    "md", "json", "toml", "yaml", "yml", "txt", "lock",
];

struct ObserveArgs {
    scope: LogScope,
    project: Option<String>,
    since_secs: Option<u64>,
    output_file: Option<PathBuf>,
    input_file: Option<PathBuf>,
}

#[derive(Default)]
struct Aggregates {
    total_events: u64,
    hook_total: BTreeMap<(String, String), u64>,
    event_total: BTreeMap<(String, String, String, String, String, String, String), u64>,
    violation_total: BTreeMap<(String, String, String, String, String, String), u64>,
    duration_sum: BTreeMap<String, f64>,
    duration_count: BTreeMap<String, u64>,
}

pub fn run(args: &[String]) -> Result {
    let opts = ObserveArgs::from_cli_args(args)?;
    let input_path = match opts.input_file.clone() {
        Some(path) => path,
        None => {
            resolve_log_file(&LogScopeOptions {
                scope: opts.scope,
                project: opts.project.clone(),
                log_file: None,
                allow_env_log_file: true,
            })?
            .path
        }
    };

    let cutoff_secs = opts
        .since_secs
        .map(|secs| time_utils::now_unix_secs().saturating_sub(secs));
    let metrics = render_prometheus_from_path(&input_path, cutoff_secs)?;

    match opts.output_file {
        Some(path) => fs::write(path, metrics)?,
        None => {
            print!("{metrics}");
        }
    }
    Ok(())
}

impl ObserveArgs {
    fn from_cli_args(args: &[String]) -> Result<Self> {
        if args.len() < 2 || args[0] != "export" || args[1] != "prometheus" {
            return Err("Usage: vibeguard-runtime observe export prometheus [--scope project|global] [--project PATH_OR_HASH] [--since 7d|24h|3600s|all] [--file OUTPUT] [--input-file EVENTS_JSONL]".into());
        }

        let mut scope = LogScope::Global;
        let mut project = None;
        let mut since_secs = Some(DEFAULT_SINCE_SECS);
        let mut output_file = None;
        let mut input_file = None;
        let mut i = 2;
        while i < args.len() {
            match args[i].as_str() {
                "--scope" => {
                    let value = require_value(args, i, "--scope")?;
                    scope = parse_scope(&value)?;
                    i += 2;
                }
                "--project" => {
                    project = Some(require_value(args, i, "--project")?);
                    i += 2;
                }
                "--since" => {
                    let value = require_value(args, i, "--since")?;
                    since_secs = parse_since(&value)?;
                    i += 2;
                }
                "--file" => {
                    output_file = Some(PathBuf::from(require_value(args, i, "--file")?));
                    i += 2;
                }
                "--input-file" => {
                    input_file = Some(PathBuf::from(require_value(args, i, "--input-file")?));
                    i += 2;
                }
                other => {
                    return Err(format!("Unknown observe export prometheus option: {other}").into());
                }
            }
        }

        Ok(Self {
            scope,
            project,
            since_secs,
            output_file,
            input_file,
        })
    }
}

fn require_value(args: &[String], index: usize, flag: &str) -> Result<String> {
    args.get(index + 1)
        .filter(|value| !value.starts_with("--"))
        .cloned()
        .ok_or_else(|| format!("{flag} requires a value").into())
}

fn parse_since(value: &str) -> Result<Option<u64>> {
    let trimmed = value.trim();
    if trimmed == "all" {
        return Ok(None);
    }
    if trimmed.is_empty() {
        return Err("--since cannot be empty".into());
    }

    let (digits, multiplier) = match trimmed.as_bytes().last().copied() {
        Some(b'd') => (&trimmed[..trimmed.len() - 1], 24 * 60 * 60),
        Some(b'h') => (&trimmed[..trimmed.len() - 1], 60 * 60),
        Some(b'm') => (&trimmed[..trimmed.len() - 1], 60),
        Some(b's') => (&trimmed[..trimmed.len() - 1], 1),
        Some(_) => (trimmed, 1),
        None => return Err("--since cannot be empty".into()),
    };
    let amount: u64 = digits
        .parse()
        .map_err(|_| "--since must be an integer duration such as 7d, 24h, 30m, or 3600s")?;
    Ok(Some(amount.saturating_mul(multiplier)))
}

fn render_prometheus_from_path(path: &Path, cutoff_secs: Option<u64>) -> Result<String> {
    match File::open(path) {
        Ok(file) => render_prometheus(file, cutoff_secs),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(e.into()),
    }
}

fn render_prometheus(reader: impl Read, cutoff_secs: Option<u64>) -> Result<String> {
    let mut aggr = Aggregates::default();
    let mut reader = io::BufReader::new(reader);
    let mut bytes = Vec::new();

    while reader.read_until(b'\n', &mut bytes)? != 0 {
        let line = String::from_utf8_lossy(&bytes);
        let trimmed = line.trim();
        if !trimmed.is_empty() {
            if let Ok(event) = serde_json::from_str::<Value>(trimmed) {
                if event_in_selected_period(&event, cutoff_secs) {
                    aggr.record_event(&event);
                }
            }
        }
        bytes.clear();
    }

    Ok(render_aggregates(&aggr))
}

fn event_in_selected_period(event: &Value, cutoff_secs: Option<u64>) -> bool {
    let Some(cutoff_secs) = cutoff_secs else {
        return true;
    };
    event
        .get(field::TS)
        .and_then(Value::as_str)
        .and_then(time_utils::parse_iso_ts)
        .is_some_and(|event_secs| event_secs >= cutoff_secs)
}

impl Aggregates {
    fn record_event(&mut self, event: &Value) {
        let hook = safe_label(field_str(event, field::HOOK), UNKNOWN);
        let tool = safe_label(field_str(event, field::TOOL), UNKNOWN);
        let event_decision = safe_label(field_str(event, field::DECISION), UNKNOWN);
        let raw_reason = field_str(event, field::REASON);
        let raw_detail = field_str(event, field::DETAIL);
        let rule_id = derive_rule_id(raw_reason);
        let reason_code = derive_reason_code(raw_reason, &rule_id);
        let severity = derive_severity(&event_decision, &rule_id);
        let file_ext = derive_file_ext(raw_detail);

        self.total_events += 1;
        *self
            .hook_total
            .entry((hook.clone(), event_decision.clone()))
            .or_default() += 1;
        *self
            .event_total
            .entry((
                hook.clone(),
                tool,
                event_decision.clone(),
                rule_id.clone(),
                reason_code.clone(),
                severity.clone(),
                file_ext.clone(),
            ))
            .or_default() += 1;

        if is_violation_decision(&event_decision) {
            *self
                .violation_total
                .entry((
                    hook.clone(),
                    event_decision,
                    rule_id,
                    reason_code,
                    severity,
                    file_ext,
                ))
                .or_default() += 1;
        }

        if let Some(duration_ms) = event.get(field::DURATION_MS).and_then(Value::as_f64) {
            if duration_ms >= 0.0 {
                *self.duration_sum.entry(hook.clone()).or_default() += duration_ms / 1000.0;
                *self.duration_count.entry(hook).or_default() += 1;
            }
        }
    }
}

fn field_str<'a>(event: &'a Value, key: &str) -> &'a str {
    event.get(key).and_then(Value::as_str).unwrap_or("")
}

fn is_violation_decision(value: &str) -> bool {
    matches!(
        value,
        decision::WARN
            | decision::BLOCK
            | decision::GATE
            | decision::ESCALATE
            | decision::CORRECTION
    )
}

fn safe_label(value: &str, fallback: &str) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return fallback.to_string();
    }
    if trimmed.len() > 64 {
        return "other".to_string();
    }
    if trimmed
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
    {
        trimmed.to_string()
    } else {
        "other".to_string()
    }
}

fn derive_rule_id(reason: &str) -> String {
    for token in reason.split(|c: char| !(c.is_ascii_alphanumeric() || c == '-')) {
        let upper = token.to_ascii_uppercase();
        if valid_rule_id(&upper) {
            return upper;
        }
    }
    "none".to_string()
}

fn valid_rule_id(token: &str) -> bool {
    let Some((prefix, tail)) = token.split_once('-') else {
        return false;
    };
    matches!(
        prefix,
        "U" | "W" | "SEC" | "RS" | "PY" | "TS" | "GO" | "PERF"
    ) && !tail.is_empty()
        && tail.len() <= 3
        && tail.bytes().all(|b| b.is_ascii_digit())
}

fn derive_reason_code(reason: &str, rule_id: &str) -> String {
    let lower = reason.to_ascii_lowercase();
    let code = if lower.trim().is_empty() {
        "unspecified"
    } else if lower.contains("malformed") || lower.contains("invalid json") {
        "malformed_input"
    } else if lower.contains("duplicate definition") {
        "duplicate_definition"
    } else if lower.contains("same-name") || lower.contains("same name") {
        "same_name_duplicate"
    } else if lower.contains("unwrap") || lower.contains("expect") {
        "unsafe_unwrap"
    } else if lower.contains("console.log") || lower.contains("debug") {
        "debug_output"
    } else if lower.contains("hardcoded")
        || lower.contains("credential")
        || lower.contains("secret")
    {
        "sensitive_literal"
    } else if lower.contains("force push")
        || lower.contains("checkout/restore")
        || lower.contains("rm -rf")
        || lower.contains("dangerous")
    {
        "dangerous_command"
    } else if lower.contains("timeout") {
        "timeout"
    } else if lower.contains("build fail") {
        "build_failed"
    } else if lower.contains("pre-commit") {
        "precommit_failed"
    } else if lower.contains("analysis paralysis") {
        "analysis_paralysis"
    } else if lower.contains("test infrastructure") {
        "test_integrity"
    } else if lower.contains("package manager") || lower.contains("pnpm") || lower.contains("uv") {
        "package_manager"
    } else if rule_id != "none" {
        "rule_violation"
    } else {
        "other"
    };
    code.to_string()
}

fn derive_severity(decision_value: &str, rule_id: &str) -> String {
    if rule_id.starts_with("SEC-") {
        return "critical".to_string();
    }
    match decision_value {
        decision::BLOCK | decision::GATE | decision::ESCALATE => "strict",
        decision::WARN | decision::CORRECTION => "guideline",
        decision::PASS | decision::COMPLETE => "info",
        _ => UNKNOWN,
    }
    .to_string()
}

fn derive_file_ext(detail: &str) -> String {
    for token in
        detail.split(|c: char| c.is_whitespace() || matches!(c, '|' | ',' | '"' | '\'' | '(' | ')'))
    {
        let token = token.trim_matches(|c: char| matches!(c, ':' | ';' | '[' | ']' | '{' | '}'));
        let Some(basename) = token.rsplit('/').next() else {
            continue;
        };
        let Some((_, ext)) = basename.rsplit_once('.') else {
            continue;
        };
        let ext = ext.to_ascii_lowercase();
        if KNOWN_EXTS.contains(&ext.as_str()) {
            return ext;
        }
        if !ext.is_empty() && ext.len() <= 12 && ext.bytes().all(|b| b.is_ascii_alphanumeric()) {
            return "other".to_string();
        }
    }
    "none".to_string()
}

fn render_aggregates(aggr: &Aggregates) -> String {
    let mut out = String::new();
    push_header(
        &mut out,
        "vibeguard_hook_trigger_total",
        "Total hook triggers by hook and decision",
        "counter",
    );
    for ((hook, event_decision), count) in &aggr.hook_total {
        push_metric(
            &mut out,
            "vibeguard_hook_trigger_total",
            &[("hook", hook), ("decision", event_decision)],
            &count.to_string(),
        );
    }

    out.push('\n');
    push_header(
        &mut out,
        "vibeguard_event_total",
        "Total VibeGuard events by low-cardinality labels",
        "counter",
    );
    for ((hook, tool, event_decision, rule_id, reason_code, severity, file_ext), count) in
        &aggr.event_total
    {
        push_metric(
            &mut out,
            "vibeguard_event_total",
            &[
                ("hook", hook),
                ("tool", tool),
                ("decision", event_decision),
                ("rule_id", rule_id),
                ("reason_code", reason_code),
                ("severity", severity),
                ("file_ext", file_ext),
            ],
            &count.to_string(),
        );
    }

    out.push('\n');
    push_header(
        &mut out,
        "vibeguard_hook_duration_seconds",
        "Hook execution duration in seconds",
        "summary",
    );
    for (hook, sum) in &aggr.duration_sum {
        push_metric(
            &mut out,
            "vibeguard_hook_duration_seconds_sum",
            &[("hook", hook)],
            &format!("{sum:.3}"),
        );
        let count = aggr.duration_count.get(hook).copied().unwrap_or(0);
        push_metric(
            &mut out,
            "vibeguard_hook_duration_seconds_count",
            &[("hook", hook)],
            &count.to_string(),
        );
    }

    out.push('\n');
    push_header(
        &mut out,
        "vibeguard_guard_violation_total",
        "Total guard violations by low-cardinality derived labels",
        "counter",
    );
    for ((hook, event_decision, rule_id, reason_code, severity, file_ext), count) in
        &aggr.violation_total
    {
        push_metric(
            &mut out,
            "vibeguard_guard_violation_total",
            &[
                ("hook", hook),
                ("decision", event_decision),
                ("rule_id", rule_id),
                ("reason_code", reason_code),
                ("severity", severity),
                ("file_ext", file_ext),
            ],
            &count.to_string(),
        );
    }

    out.push('\n');
    push_header(
        &mut out,
        "vibeguard_events_total",
        "Total events in the selected period",
        "gauge",
    );
    out.push_str(&format!("vibeguard_events_total {}\n", aggr.total_events));
    out
}

fn push_header(out: &mut String, name: &str, help: &str, metric_type: &str) {
    out.push_str(&format!("# HELP {name} {help}\n"));
    out.push_str(&format!("# TYPE {name} {metric_type}\n"));
}

fn push_metric(out: &mut String, name: &str, labels: &[(&str, &String)], value: &str) {
    out.push_str(name);
    out.push('{');
    for (index, (label, label_value)) in labels.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        out.push_str(label);
        out.push_str("=\"");
        out.push_str(&prometheus_escape(label_value));
        out.push('"');
    }
    out.push_str("} ");
    out.push_str(value);
    out.push('\n');
}

fn prometheus_escape(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('\n', "\\n")
        .replace('"', "\\\"")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io;

    fn render(input: &str) -> String {
        render_prometheus(io::Cursor::new(input), Some(0)).unwrap()
    }

    #[test]
    fn prometheus_export_uses_safe_derived_labels() {
        let input = concat!(
            "{\"ts\":\"2026-05-31T00:00:00Z\",\"session\":\"secret-session\",",
            "\"hook\":\"post-edit-guard\",\"tool\":\"Edit\",\"decision\":\"warn\",",
            "\"reason\":\"U-16 block for customer@example.com command cargo test -- --ignored\",",
            "\"detail\":\"Edit /Users/alice/project/src/private_token.rs\",",
            "\"duration_ms\":250}\n"
        );
        let out = render(input);

        assert!(out.contains("vibeguard_event_total"));
        assert!(out.contains("rule_id=\"U-16\""));
        assert!(out.contains("reason_code=\"rule_violation\""));
        assert!(out.contains("file_ext=\"rs\""));
        assert!(out.contains("vibeguard_hook_duration_seconds_sum"));
        for raw in [
            "secret-session",
            "customer@example.com",
            "cargo test -- --ignored",
            "/Users/alice",
            "private_token",
        ] {
            assert!(
                !out.contains(raw),
                "raw value leaked in metrics: {raw}\n{out}"
            );
        }
    }

    #[test]
    fn parse_since_supports_units_and_all() {
        assert_eq!(parse_since("7d").unwrap(), Some(604800));
        assert_eq!(parse_since("2h").unwrap(), Some(7200));
        assert_eq!(parse_since("30m").unwrap(), Some(1800));
        assert_eq!(parse_since("15s").unwrap(), Some(15));
        assert_eq!(parse_since("42").unwrap(), Some(42));
        assert_eq!(parse_since("all").unwrap(), None);
    }

    #[test]
    fn unknown_freeform_reason_uses_other_code() {
        let input = concat!(
            "{\"ts\":\"2026-05-31T00:00:00Z\",",
            "\"hook\":\"pre-bash-guard\",\"tool\":\"Bash\",\"decision\":\"block\",",
            "\"reason\":\"user typed deploy-prod --token abc123\",",
            "\"detail\":\"deploy-prod --token abc123\"}\n"
        );
        let out = render(input);
        assert!(out.contains("reason_code=\"other\""));
        assert!(out.contains("file_ext=\"none\""));
        assert!(!out.contains("deploy-prod"));
        assert!(!out.contains("abc123"));
    }
}
