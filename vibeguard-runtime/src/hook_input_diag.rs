use serde_json::Value;

use crate::hook_checks_common::{nested_str, truncate_chars};

const MALFORMED_DIAG_HEAD_CHARS: usize = 80;

/// Distinguish the three fail-closed input shapes (empty stdin, invalid JSON,
/// well-formed JSON missing the required field) so block events in
/// events.jsonl are diagnosable without the original payload.
pub(crate) fn malformed_input_diagnostic(input: &str, required_field: &str) -> String {
    if input.trim().is_empty() {
        return format!("empty hook stdin ({} bytes)", input.len());
    }
    match serde_json::from_str::<Value>(input) {
        Err(err) => format!(
            "invalid JSON ({} chars; {err}); head={}",
            input.chars().count(),
            truncate_chars(input.trim_start(), MALFORMED_DIAG_HEAD_CHARS)
        ),
        Ok(data) => {
            let tool_name =
                nested_str(&data, "tool_name").unwrap_or_else(|| "<absent>".to_string());
            let event_name =
                nested_str(&data, "hook_event_name").unwrap_or_else(|| "<absent>".to_string());
            format!(
                "JSON ok but {required_field} missing, empty, or not a string; tool_name={tool_name} hook_event_name={event_name}"
            )
        }
    }
}
