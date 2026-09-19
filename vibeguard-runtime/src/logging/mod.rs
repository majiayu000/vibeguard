use crate::Result;
use crate::setup::support::{read_optional, write_atomic};
use serde_json::{Value, json};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn record(
    state_dir: &Path,
    host: &str,
    input: &Value,
    outcome: &str,
    exit_code: Option<i64>,
) -> Result<()> {
    let record = json!({
        "observed_at_unix_ms": SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis(),
        "host": host,
        "event": input["hook_event_name"],
        "tool": "Bash",
        "tool_use_id": input.get("tool_use_id").and_then(Value::as_str),
        "cwd": input["cwd"],
        "outcome": outcome,
        "exit_code": exit_code
    });
    // Only the latest observation is retained. Commands, output and credentials
    // are never copied into this diagnostic file.
    write_atomic(
        &state_dir.join(format!("{host}.json")),
        &(serde_json::to_string_pretty(&record)? + "\n").into_bytes(),
        0o600,
    )
}

pub fn latest(state_dir: &Path, host: &str) -> Result<Option<Value>> {
    read_optional(&state_dir.join(format!("{host}.json")))?
        .map(|bytes| {
            let value: Value =
                serde_json::from_slice(&bytes).map_err(|_| "invalid VibeGuard observation JSON")?;
            if !value.is_object() {
                return Err("VibeGuard observation must be an object".into());
            }
            Ok(value)
        })
        .transpose()
}
