//! Latest observed event for each client in a project-scoped JSONL log.

use serde_json::Value;
use std::collections::BTreeMap;
use std::io::{self, BufRead};

use crate::event_schema::{UNKNOWN, field};

type ClientEvent = (String, String, String, String);
type Result = std::result::Result<(), Box<dyn std::error::Error>>;

fn read_events(
    reader: impl BufRead,
) -> std::result::Result<Vec<Value>, Box<dyn std::error::Error>> {
    let mut events = Vec::new();
    for (index, line) in reader.lines().enumerate() {
        let line = line?;
        let event = serde_json::from_str::<Value>(&line)
            .map_err(|error| format!("invalid JSONL record at line {}: {error}", index + 1))?;
        events.push(event);
    }
    Ok(events)
}

fn string_field<'a>(event: &'a Value, names: &[&str]) -> Option<&'a str> {
    names
        .iter()
        .find_map(|name| event.get(name).and_then(Value::as_str))
        .filter(|value| !value.is_empty())
}

fn latest_client_events(events: &[Value]) -> Vec<ClientEvent> {
    let mut latest = BTreeMap::<String, ClientEvent>::new();
    for event in events {
        let Some(client) = string_field(event, &[field::CLIENT, field::CLI, "agent_type"]) else {
            continue;
        };
        let Some(ts) = string_field(event, &[field::TS]) else {
            continue;
        };
        if latest
            .get(client)
            .is_some_and(|(_, latest_ts, _, _)| latest_ts.as_str() > ts)
        {
            continue;
        }
        let hook = string_field(event, &[field::HOOK]).unwrap_or(UNKNOWN);
        let outcome = string_field(event, &[field::DECISION, field::STATUS]).unwrap_or(UNKNOWN);
        latest.insert(
            client.to_string(),
            (
                client.to_string(),
                ts.to_string(),
                hook.to_string(),
                outcome.to_string(),
            ),
        );
    }
    latest.into_values().collect()
}

fn tsv_field(value: &str) -> String {
    value.replace(['\t', '\r', '\n'], " ")
}

/// Emit the latest event for every observed client, sorted by client name.
pub fn run(args: &[String]) -> Result {
    if !args.is_empty() {
        return Err("Usage: cat events.jsonl | vibeguard-runtime latest-client-events".into());
    }

    let stdin = io::stdin();
    let events = read_events(stdin.lock())?;
    for (client, ts, hook, outcome) in latest_client_events(&events) {
        println!(
            "{}\t{}\t{}\t{}",
            tsv_field(&client),
            tsv_field(&ts),
            tsv_field(&hook),
            tsv_field(&outcome)
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn uses_identity_fallbacks_and_latest_timestamp() {
        let events = vec![
            json!({"client": "claude", "ts": "2026-08-31T08:00:00Z", "hook": "older", "decision": "pass"}),
            json!({"client": "claude", "ts": "2026-08-31T10:00:00Z", "hook": "newer", "decision": "warn"}),
            json!({"cli": "codex", "ts": "2026-08-31T09:00:00Z", "hook": "codex-hook", "status": "pass"}),
            json!({"agent_type": "gemini", "ts": "2026-08-31T07:00:00Z", "hook": "gemini-hook", "decision": "block"}),
            json!({"client": "claude", "hook": "missing-ts", "decision": "pass"}),
            json!({"ts": "2026-08-31T11:00:00Z", "hook": "missing-client", "decision": "pass"}),
        ];

        assert_eq!(
            latest_client_events(&events),
            vec![
                (
                    "claude".to_string(),
                    "2026-08-31T10:00:00Z".to_string(),
                    "newer".to_string(),
                    "warn".to_string(),
                ),
                (
                    "codex".to_string(),
                    "2026-08-31T09:00:00Z".to_string(),
                    "codex-hook".to_string(),
                    "pass".to_string(),
                ),
                (
                    "gemini".to_string(),
                    "2026-08-31T07:00:00Z".to_string(),
                    "gemini-hook".to_string(),
                    "block".to_string(),
                ),
            ]
        );
    }

    #[test]
    fn rejects_malformed_jsonl_records() {
        let input = std::io::Cursor::new("{\"client\":\"claude\"}\n{\n");
        let error = read_events(input).expect_err("malformed JSONL must fail");
        assert!(error.to_string().contains("line 2"));
    }
}
