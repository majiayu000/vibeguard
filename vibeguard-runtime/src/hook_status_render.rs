use serde_json::{Value, json};

use crate::event_schema::{UNKNOWN, status};

use super::{HOOK_STATUS_SCHEMA_VERSION, HookStatusEntry, Mode, Result, non_empty_or};

pub(super) fn render_json(entries: &[HookStatusEntry], mode: Mode) -> Result<String> {
    let summary = summary_json(entries);
    let mode_value = match mode {
        Mode::Minimal => "minimal",
        Mode::Focused => "focused",
        Mode::Full => "full",
    };
    let payload = json!({
        "schema_version": HOOK_STATUS_SCHEMA_VERSION,
        "mode": mode_value,
        "summary": summary,
        "entries": entries.iter().map(HookStatusEntry::to_json).collect::<Vec<_>>(),
    });
    Ok(serde_json::to_string_pretty(&payload)?)
}

pub(super) fn render_human(entries: &[HookStatusEntry], mode: Mode) -> String {
    if entries.is_empty() {
        return "No hook status events found.\n".to_string();
    }

    let mut out = String::new();
    out.push_str(&minimal_line(entries));
    out.push('\n');

    if matches!(mode, Mode::Focused | Mode::Full) {
        for entry in entries {
            out.push_str(&format_entry_line(entry, mode));
            out.push('\n');
        }
    }
    out
}

pub(super) fn minimal_line(entries: &[HookStatusEntry]) -> String {
    let summary_entries = summary_entries(entries);
    let event = summary_entries
        .last()
        .map(|entry| entry.event.as_str())
        .unwrap_or(UNKNOWN);
    if let Some(entry) = summary_entries
        .iter()
        .rev()
        .find(|entry| entry.status == status::TIMEOUT)
    {
        return format!(
            "{} hook timed out - {} - {}\nLast action: {}\nLog: {}\nSafe to interrupt: {}",
            entry.event,
            entry.hook,
            format_duration(entry.display_duration_ms()),
            non_empty_or(entry.detail.clone(), UNKNOWN),
            non_empty_or(entry.log_path.clone(), UNKNOWN),
            if entry.event == "PostToolUse" {
                "yes, hook ran after the tool action"
            } else {
                "check the hook event before interrupting"
            }
        );
    }
    if let Some(entry) = summary_entries
        .iter()
        .rev()
        .find(|entry| entry.status == status::ADAPTER_ERROR)
    {
        return format!(
            "{} hook adapter_error - {} - {}\nLast action: {}\nLog: {}",
            entry.event,
            entry.hook,
            non_empty_or(entry.reason.clone(), UNKNOWN),
            non_empty_or(entry.detail.clone(), UNKNOWN),
            non_empty_or(entry.log_path.clone(), UNKNOWN)
        );
    }

    let total = summary_entries.len();
    let running = summary_entries
        .iter()
        .filter(|entry| entry.is_running())
        .count();
    if running > 0 {
        let elapsed = summary_entries
            .iter()
            .filter(|entry| entry.is_running())
            .filter_map(|entry| entry.display_duration_ms())
            .max();
        let timeout = summary_entries
            .iter()
            .filter(|entry| entry.is_running())
            .filter_map(|entry| entry.timeout_ms)
            .max();
        return format!(
            "{} checks  {}/{} running - {} / {}",
            event,
            running,
            total,
            format_duration(elapsed),
            format_duration(timeout)
        );
    }

    let total_duration = summary_entries
        .iter()
        .filter_map(|entry| entry.duration_ms)
        .sum::<u64>();
    format!(
        "{} checks  {}/{} complete - {}",
        event,
        total,
        total,
        format_duration(Some(total_duration))
    )
}

fn summary_json(entries: &[HookStatusEntry]) -> Value {
    let summary_entries = summary_entries(entries);
    let total = summary_entries.len();
    let running = summary_entries
        .iter()
        .filter(|entry| entry.is_running())
        .count();
    let attention = summary_entries
        .iter()
        .filter(|entry| entry.is_attention_state())
        .count();
    let model_context = summary_entries
        .iter()
        .filter(|entry| entry.model_context)
        .count();
    let event = summary_entries
        .last()
        .map(|entry| entry.event.as_str())
        .unwrap_or(UNKNOWN);
    json!({
        "event": event,
        "total": total,
        "complete": total.saturating_sub(running),
        "running": running,
        "attention": attention,
        "model_context_entries": model_context,
    })
}

fn summary_entries(entries: &[HookStatusEntry]) -> Vec<&HookStatusEntry> {
    let Some(event) = entries.last().map(|entry| entry.event.as_str()) else {
        return Vec::new();
    };
    entries
        .iter()
        .filter(|entry| entry.event == event)
        .collect::<Vec<_>>()
}

fn format_entry_line(entry: &HookStatusEntry, mode: Mode) -> String {
    let mut line = format!(
        "[{}] {} {}({}) {}",
        status_label(&entry.status),
        entry.hook,
        entry.event,
        entry.matcher,
        entry.status
    );
    if !entry.reason.is_empty() {
        line.push_str(" - ");
        line.push_str(&entry.reason);
    }
    if let Some(ms) = entry.display_duration_ms() {
        line.push_str(" - ");
        line.push_str(&format_duration(Some(ms)));
    }
    if entry.status == status::RUNNING {
        if let Some(timeout_ms) = entry.timeout_ms {
            line.push_str(" / ");
            line.push_str(&format_duration(Some(timeout_ms)));
        }
    }
    if matches!(mode, Mode::Full) {
        line.push_str(&format!(
            " - model_context={} - log={}",
            entry.model_context,
            non_empty_or(entry.log_path.clone(), UNKNOWN)
        ));
        if !entry.detail.is_empty() {
            line.push_str(" - last_action=");
            line.push_str(&entry.detail);
        }
    }
    line
}

fn status_label(value: &str) -> &str {
    match value {
        status::PASS => "pass",
        status::SKIPPED => "skip",
        status::WARN => "warn",
        status::BLOCK => "block",
        status::SLOW => "slow",
        status::TIMEOUT => "timeout",
        status::RUNNING => "running",
        status::ADAPTER_ERROR => "error",
        status::HOOK_ERROR => "error",
        _ => "info",
    }
}

fn format_duration(ms: Option<u64>) -> String {
    match ms {
        None => "?".to_string(),
        Some(value) if value < 1_000 => format!("{value}ms"),
        Some(value) if value % 1_000 == 0 => format!("{}s", value / 1_000),
        Some(value) => format!("{:.1}s", value as f64 / 1_000.0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(event: &str, status_value: &str, duration_ms: Option<u64>) -> HookStatusEntry {
        HookStatusEntry {
            ts: "2026-05-31T00:00:00Z".to_string(),
            session: "s1".to_string(),
            source: "event_log".to_string(),
            hook: "post-build-check".to_string(),
            event: event.to_string(),
            matcher: "<none>".to_string(),
            status: status_value.to_string(),
            decision: status_value.to_string(),
            reason: String::new(),
            detail: String::new(),
            duration_ms,
            elapsed_ms: None,
            timeout_ms: None,
            model_context: status_value == status::WARN,
            log_path: "events.jsonl".to_string(),
        }
    }

    #[test]
    fn minimal_summary_counts_only_last_event() {
        let entries = vec![
            entry("Bash", status::PASS, Some(18)),
            entry("PostToolUse", status::SKIPPED, Some(28)),
        ];
        assert_eq!(
            minimal_line(&entries),
            "PostToolUse checks  1/1 complete - 28ms"
        );
    }

    #[test]
    fn json_summary_counts_only_last_event_but_keeps_entries() {
        let entries = vec![
            entry("Bash", status::PASS, Some(18)),
            entry("Bash", status::WARN, Some(44)),
            entry("PostToolUse", status::SKIPPED, Some(28)),
        ];
        let payload: Value = serde_json::from_str(&render_json(&entries, Mode::Full).unwrap())
            .expect("hook-status JSON should parse");

        assert_eq!(payload["summary"]["event"], "PostToolUse");
        assert_eq!(payload["summary"]["total"], 1);
        assert_eq!(payload["summary"]["attention"], 0);
        assert_eq!(payload["entries"].as_array().unwrap().len(), 3);
    }
}
