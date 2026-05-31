//! Human-facing hook status summaries for Codex/Claude hook JSONL events.
//!
//! This command intentionally reports pass/skip/slow/timeout states outside the
//! hook output contract, so successful hooks stay out of the model context.

use serde_json::{Value, json};
use std::env;
use std::fs::File;
use std::io::{self, BufRead, IsTerminal, Read};
use std::path::{Path, PathBuf};

use crate::event_schema::{UNKNOWN, decision, field, status, tool};
use crate::time_utils::{now_unix_secs, parse_iso_ts};

#[path = "hook_status_render.rs"]
mod hook_status_render;
#[cfg(test)]
use hook_status_render::minimal_line;
use hook_status_render::{render_human, render_json};

type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;

const HOOK_STATUS_SCHEMA_VERSION: u64 = 1;
const DEFAULT_LIMIT: usize = 20;
const DEFAULT_SLOW_MS: u64 = 2_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Mode {
    Minimal,
    Focused,
    Full,
}

#[derive(Debug)]
struct Options {
    mode: Mode,
    json: bool,
    limit: usize,
    slow_ms: u64,
    log_file: Option<PathBuf>,
    diag_file: Option<PathBuf>,
    session: Option<String>,
    event: Option<String>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            mode: Mode::Minimal,
            json: false,
            limit: DEFAULT_LIMIT,
            slow_ms: DEFAULT_SLOW_MS,
            log_file: None,
            diag_file: None,
            session: None,
            event: None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct HookStatusEntry {
    ts: String,
    session: String,
    source: String,
    hook: String,
    event: String,
    matcher: String,
    status: String,
    decision: String,
    reason: String,
    detail: String,
    duration_ms: Option<u64>,
    elapsed_ms: Option<u64>,
    timeout_ms: Option<u64>,
    model_context: bool,
    log_path: String,
}

impl HookStatusEntry {
    fn to_json(&self) -> Value {
        json!({
            field::TS: self.ts,
            field::SESSION: self.session,
            field::SOURCE: self.source,
            field::HOOK: self.hook,
            field::EVENT: self.event,
            field::MATCHER: self.matcher,
            field::STATUS: self.status,
            field::DECISION: self.decision,
            field::REASON: self.reason,
            field::DETAIL: self.detail,
            field::DURATION_MS: self.duration_ms,
            field::ELAPSED_MS: self.elapsed_ms,
            field::TIMEOUT_MS: self.timeout_ms,
            field::MODEL_CONTEXT: self.model_context,
            field::LOG_PATH: self.log_path,
        })
    }

    fn is_running(&self) -> bool {
        self.status == status::RUNNING
    }

    fn is_attention_state(&self) -> bool {
        matches!(
            self.status.as_str(),
            status::WARN
                | status::BLOCK
                | status::GATE
                | status::ESCALATE
                | status::CORRECTION
                | status::TIMEOUT
                | status::ADAPTER_ERROR
                | status::HOOK_ERROR
        )
    }

    fn display_duration_ms(&self) -> Option<u64> {
        self.elapsed_ms.or(self.duration_ms)
    }
}

pub fn run(args: &[String]) -> Result {
    let options = parse_args(args)?;
    let (main_events, log_path) = read_main_events(&options)?;
    let mut entries = Vec::new();
    for event in main_events {
        let entry = normalize_hook_event(&event, &log_path, options.slow_ms);
        if entry_matches_filters(&entry, &options) {
            entries.push(entry);
        }
    }

    for diag_source in read_diag_events(&options)? {
        let entry = normalize_diag_event(&diag_source.event, &diag_source.log_path);
        if entry_matches_filters(&entry, &options) {
            entries.push(entry);
        }
    }

    entries.sort_by(|a, b| {
        a.ts.cmp(&b.ts)
            .then_with(|| entry_sort_rank(a).cmp(&entry_sort_rank(b)))
    });
    let entries = drop_stale_running(entries);
    let entries = latest_entries(entries, options.limit);

    if options.json {
        println!("{}", render_json(&entries, options.mode)?);
    } else {
        print!("{}", render_human(&entries, options.mode));
    }
    Ok(())
}

fn parse_args(args: &[String]) -> Result<Options> {
    let mut options = Options::default();
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--json" => options.json = true,
            "--mode" => {
                index += 1;
                let mode = args
                    .get(index)
                    .ok_or("--mode requires minimal|focused|full")?;
                options.mode = parse_mode(mode)?;
            }
            "--limit" => {
                index += 1;
                let value = args
                    .get(index)
                    .ok_or("--limit requires a positive integer")?;
                options.limit = value.parse::<usize>()?;
                if options.limit == 0 {
                    return Err("--limit must be greater than 0".into());
                }
            }
            "--slow-ms" => {
                index += 1;
                let value = args.get(index).ok_or("--slow-ms requires milliseconds")?;
                options.slow_ms = value.parse::<u64>()?;
            }
            "--log-file" => {
                index += 1;
                let value = args.get(index).ok_or("--log-file requires a path")?;
                options.log_file = Some(PathBuf::from(value));
            }
            "--diag-file" => {
                index += 1;
                let value = args.get(index).ok_or("--diag-file requires a path")?;
                options.diag_file = Some(PathBuf::from(value));
            }
            "--session" => {
                index += 1;
                let value = args.get(index).ok_or("--session requires a value")?;
                options.session = Some(value.to_string());
            }
            "--event" => {
                index += 1;
                let value = args.get(index).ok_or("--event requires a value")?;
                options.event = Some(value.to_string());
            }
            "--help" | "-h" => {
                return Err("Usage: vibeguard-runtime hook-status [--mode minimal|focused|full] [--json] [--limit N] [--slow-ms MS] [--log-file PATH] [--diag-file PATH] [--session ID] [--event EVENT]".into());
            }
            other => return Err(format!("unknown hook-status argument: {other}").into()),
        }
        index += 1;
    }
    Ok(options)
}

fn parse_mode(value: &str) -> Result<Mode> {
    match value {
        "minimal" => Ok(Mode::Minimal),
        "focused" => Ok(Mode::Focused),
        "full" => Ok(Mode::Full),
        _ => Err("mode must be one of: minimal, focused, full".into()),
    }
}

fn read_main_events(options: &Options) -> Result<(Vec<Value>, String)> {
    if let Some(path) = &options.log_file {
        return Ok((read_jsonl_file(path)?, display_path(path)));
    }

    let stdin_events = read_jsonl_from_stdin()?;
    if !stdin_events.is_empty() {
        return Ok((stdin_events, "stdin".to_string()));
    }

    if let Some(path) = default_event_log_path() {
        if path.exists() {
            return Ok((read_jsonl_file(&path)?, display_path(&path)));
        }
    }

    Ok((Vec::new(), "stdin".to_string()))
}

struct DiagSource {
    event: Value,
    log_path: String,
}

fn read_diag_events(options: &Options) -> Result<Vec<DiagSource>> {
    let path = if let Some(path) = &options.diag_file {
        path.clone()
    } else if let Ok(path) = env::var("VIBEGUARD_CODEX_DIAG_FILE") {
        PathBuf::from(path)
    } else {
        match env::var("HOME") {
            Ok(home) => PathBuf::from(home).join(".vibeguard/codex-wrapper.jsonl"),
            Err(_) => return Ok(Vec::new()),
        }
    };

    if !path.exists() {
        return Ok(Vec::new());
    }

    let log_path = display_path(&path);
    Ok(read_jsonl_file(&path)?
        .into_iter()
        .map(|event| DiagSource {
            event,
            log_path: log_path.clone(),
        })
        .collect())
}

fn read_jsonl_file(path: &Path) -> Result<Vec<Value>> {
    let mut file = File::open(path)?;
    let mut text = String::new();
    file.read_to_string(&mut text)?;
    Ok(read_jsonl_text(&text))
}

fn read_jsonl_from_stdin() -> Result<Vec<Value>> {
    if io::stdin().is_terminal() {
        return Ok(Vec::new());
    }

    let stdin = io::stdin();
    let mut reader = io::BufReader::new(stdin.lock());
    let mut lines = Vec::new();
    let mut buf = Vec::new();
    loop {
        buf.clear();
        match reader.read_until(b'\n', &mut buf)? {
            0 => break,
            _ => {
                let line = String::from_utf8_lossy(&buf);
                if let Ok(value) = serde_json::from_str::<Value>(line.trim()) {
                    lines.push(value);
                }
            }
        }
    }
    Ok(lines)
}

fn read_jsonl_text(text: &str) -> Vec<Value> {
    text.lines()
        .filter_map(|line| serde_json::from_str::<Value>(line.trim()).ok())
        .collect()
}

fn default_event_log_path() -> Option<PathBuf> {
    if let Ok(path) = env::var("VIBEGUARD_LOG_FILE") {
        return Some(PathBuf::from(path));
    }
    env::var("HOME")
        .ok()
        .map(|home| PathBuf::from(home).join(".vibeguard/events.jsonl"))
}

fn display_path(path: &Path) -> String {
    if let Ok(home) = env::var("HOME") {
        let home_path = PathBuf::from(home);
        if let Ok(stripped) = path.strip_prefix(&home_path) {
            return format!("~/{}", stripped.to_string_lossy());
        }
    }
    path.to_string_lossy().to_string()
}

fn normalize_hook_event(value: &Value, log_path: &str, slow_ms: u64) -> HookStatusEntry {
    let reason = string_field(value, field::REASON);
    let detail = string_field(value, field::DETAIL);
    let decision_value = string_field(value, field::DECISION);
    let duration_ms = numeric_field(value, field::DURATION_MS);
    let elapsed_ms = numeric_field(value, field::ELAPSED_MS).or(duration_ms);
    let timeout_ms = numeric_field(value, field::TIMEOUT_MS);
    let hook_name = non_empty_or(string_field(value, field::HOOK), UNKNOWN);
    let event = infer_event(value, &hook_name);
    let matcher = infer_matcher(value);
    let status_value = string_field(value, field::STATUS);
    let normalized_status = normalize_status(
        &status_value,
        &decision_value,
        &reason,
        duration_ms,
        slow_ms,
        false,
    );

    HookStatusEntry {
        ts: string_field(value, field::TS),
        session: string_field(value, field::SESSION),
        source: "event_log".to_string(),
        hook: hook_name,
        event,
        matcher,
        status: normalized_status.clone(),
        decision: decision_value,
        reason: normalize_reason(&reason, &normalized_status),
        detail,
        duration_ms,
        elapsed_ms,
        timeout_ms,
        model_context: model_context_for_status(&normalized_status),
        log_path: value
            .get(field::LOG_PATH)
            .and_then(Value::as_str)
            .unwrap_or(log_path)
            .to_string(),
    }
}

fn normalize_diag_event(value: &Value, log_path: &str) -> HookStatusEntry {
    let reason = string_field(value, field::REASON);
    let hook_name = non_empty_or(string_field(value, field::HOOK), UNKNOWN);
    let event = non_empty_or(string_field(value, field::EVENT), UNKNOWN);
    let explicit_status = string_field(value, field::STATUS);
    if !explicit_status.is_empty() {
        let duration_ms = numeric_field(value, field::DURATION_MS);
        let normalized_status = normalize_status(
            &explicit_status,
            &string_field(value, field::DECISION),
            &reason,
            duration_ms,
            DEFAULT_SLOW_MS,
            false,
        );
        let elapsed_ms =
            normalize_elapsed_ms(&normalized_status, &string_field(value, field::TS), value);
        return HookStatusEntry {
            ts: string_field(value, field::TS),
            session: string_field(value, field::SESSION),
            source: "codex_diag".to_string(),
            hook: hook_name,
            event,
            matcher: non_empty_or(string_field(value, field::MATCHER), "<none>"),
            status: normalized_status.clone(),
            decision: string_field(value, field::DECISION),
            reason: normalize_reason(&reason, &normalized_status),
            detail: string_field(value, field::DETAIL),
            duration_ms,
            elapsed_ms,
            timeout_ms: numeric_field(value, field::TIMEOUT_MS),
            model_context: model_context_for_status(&normalized_status),
            log_path: log_path.to_string(),
        };
    }

    let status_value = if is_adapter_error_reason(&reason) {
        status::ADAPTER_ERROR
    } else {
        status::HOOK_ERROR
    };

    HookStatusEntry {
        ts: string_field(value, field::TS),
        session: string_field(value, field::SESSION),
        source: "codex_diag".to_string(),
        hook: hook_name,
        event,
        matcher: non_empty_or(string_field(value, field::MATCHER), "<none>"),
        status: status_value.to_string(),
        decision: String::new(),
        reason,
        detail: string_field(value, field::DETAIL),
        duration_ms: numeric_field(value, field::DURATION_MS),
        elapsed_ms: numeric_field(value, field::ELAPSED_MS),
        timeout_ms: numeric_field(value, field::TIMEOUT_MS),
        model_context: false,
        log_path: log_path.to_string(),
    }
}

fn normalize_elapsed_ms(normalized_status: &str, ts: &str, value: &Value) -> Option<u64> {
    let explicit = numeric_field(value, field::ELAPSED_MS);
    if normalized_status != status::RUNNING {
        return explicit.or_else(|| numeric_field(value, field::DURATION_MS));
    }
    match explicit {
        Some(ms) if ms > 0 => Some(ms),
        _ => parse_iso_ts(ts).map(|started| now_unix_secs().saturating_sub(started) * 1_000),
    }
}

fn string_field(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string()
}

fn numeric_field(value: &Value, key: &str) -> Option<u64> {
    value
        .get(key)
        .and_then(|raw| raw.as_u64().or_else(|| raw.as_str()?.parse::<u64>().ok()))
}

fn non_empty_or(value: String, fallback: &str) -> String {
    if value.is_empty() {
        fallback.to_string()
    } else {
        value
    }
}

fn infer_event(value: &Value, hook_name: &str) -> String {
    for key in [field::EVENT, "hook_event_name", "hookEventName"] {
        let candidate = string_field(value, key);
        if !candidate.is_empty() {
            return candidate;
        }
    }

    let tool_value = string_field(value, field::TOOL);
    match tool_value.as_str() {
        "PreToolUse" | "PermissionRequest" | "PostToolUse" | "Stop" | "SessionStart" => tool_value,
        _ if hook_name.contains("pre-") => "PreToolUse".to_string(),
        _ if hook_name.contains("post-") => "PostToolUse".to_string(),
        _ if hook_name.contains("stop-guard") || hook_name.contains("learn-evaluator") => {
            "Stop".to_string()
        }
        _ => UNKNOWN.to_string(),
    }
}

fn infer_matcher(value: &Value) -> String {
    let matcher = string_field(value, field::MATCHER);
    if !matcher.is_empty() {
        return matcher;
    }

    match string_field(value, field::TOOL).as_str() {
        tool::BASH | tool::EDIT | tool::WRITE | tool::READ | tool::GLOB | tool::GREP => {
            string_field(value, field::TOOL)
        }
        _ => "<none>".to_string(),
    }
}

fn normalize_status(
    explicit_status: &str,
    decision_value: &str,
    reason: &str,
    duration_ms: Option<u64>,
    slow_ms: u64,
    force_adapter_error: bool,
) -> String {
    if force_adapter_error {
        return status::ADAPTER_ERROR.to_string();
    }

    let status_lower = explicit_status.to_ascii_lowercase();
    let decision_lower = decision_value.to_ascii_lowercase();
    let reason_lower = reason.to_ascii_lowercase();

    if status_lower == status::RUNNING || decision_lower == status::RUNNING {
        return status::RUNNING.to_string();
    }
    if status_lower == status::TIMEOUT || reason_lower.contains("timeout") {
        return status::TIMEOUT.to_string();
    }
    if status_lower == status::ADAPTER_ERROR || is_adapter_error_reason(reason) {
        return status::ADAPTER_ERROR.to_string();
    }
    if status_lower == status::HOOK_ERROR {
        return status::HOOK_ERROR.to_string();
    }
    if reason_lower.starts_with("skip:")
        || reason_lower.starts_with("skipped")
        || reason_lower.contains(" skipped")
    {
        return status::SKIPPED.to_string();
    }
    if decision_lower == decision::PASS && duration_ms.is_some_and(|ms| ms >= slow_ms) {
        return status::SLOW.to_string();
    }

    match decision_lower.as_str() {
        decision::PASS => status::PASS,
        decision::WARN => status::WARN,
        decision::BLOCK => status::BLOCK,
        decision::GATE => status::GATE,
        decision::ESCALATE => status::ESCALATE,
        decision::CORRECTION => status::CORRECTION,
        decision::COMPLETE => status::COMPLETE,
        "" => status::UNKNOWN,
        _ => decision_lower.as_str(),
    }
    .to_string()
}

fn normalize_reason(reason: &str, normalized_status: &str) -> String {
    if normalized_status == status::SKIPPED {
        reason
            .strip_prefix("skip:")
            .or_else(|| reason.strip_prefix("skipped:"))
            .unwrap_or(reason)
            .trim()
            .to_string()
    } else {
        reason.to_string()
    }
}

fn is_adapter_error_reason(reason: &str) -> bool {
    matches!(
        reason,
        "posttool-adapter-failed"
            | "missing-adapter"
            | "normalizer-failed"
            | "missing-runner"
            | "policy_error"
            | "missing-repo-path"
    )
}

fn model_context_for_status(normalized_status: &str) -> bool {
    matches!(
        normalized_status,
        status::WARN | status::BLOCK | status::GATE | status::ESCALATE | status::CORRECTION
    )
}

fn entry_matches_filters(entry: &HookStatusEntry, options: &Options) -> bool {
    if let Some(session) = &options.session {
        if !session.is_empty() && entry.source == "event_log" && entry.session != *session {
            return false;
        }
    }

    if let Some(event) = &options.event {
        if &entry.event != event {
            return false;
        }
    }

    true
}

fn latest_entries(mut entries: Vec<HookStatusEntry>, limit: usize) -> Vec<HookStatusEntry> {
    if entries.len() <= limit {
        return entries;
    }
    entries.drain(0..entries.len() - limit);
    entries
}

fn entry_sort_rank(entry: &HookStatusEntry) -> u8 {
    if entry.is_running() { 0 } else { 1 }
}

fn drop_stale_running(entries: Vec<HookStatusEntry>) -> Vec<HookStatusEntry> {
    let mut kept = Vec::new();
    for (index, entry) in entries.iter().enumerate() {
        if entry.is_running()
            && entries
                .iter()
                .skip(index + 1)
                .any(|later| !later.is_running() && same_hook_event(entry, later))
        {
            continue;
        }
        kept.push(entry.clone());
    }
    kept
}

fn same_hook_event(left: &HookStatusEntry, right: &HookStatusEntry) -> bool {
    left.event == right.event && canonical_hook_name(&left.hook) == canonical_hook_name(&right.hook)
}

fn canonical_hook_name(hook_name: &str) -> String {
    hook_name
        .strip_prefix("vibeguard-")
        .unwrap_or(hook_name)
        .strip_suffix(".sh")
        .unwrap_or_else(|| hook_name.strip_prefix("vibeguard-").unwrap_or(hook_name))
        .to_string()
}

#[cfg(test)]
#[path = "hook_status_tests.rs"]
mod hook_status_tests;
