//! Latest observed event for each client in a project-scoped JSONL log.

use serde_json::Value;
use std::collections::BTreeMap;
use std::io::{self, BufRead};

use crate::event_schema::field;
use crate::time_utils::parse_iso_ts;

type ClientEvent = (String, String, String, String);
type TimedClientEvent = (u64, ClientEvent);
type Result = std::result::Result<(), Box<dyn std::error::Error>>;

fn latest_client_events(
    reader: impl BufRead,
) -> std::result::Result<Vec<ClientEvent>, Box<dyn std::error::Error>> {
    let mut latest = BTreeMap::<String, TimedClientEvent>::new();
    for (index, line) in reader.lines().enumerate() {
        let line = line?;
        let event = serde_json::from_str::<Value>(&line)
            .map_err(|error| format!("invalid JSONL record at line {}: {error}", index + 1))?;
        let Some(client) = string_field(&event, &[field::CLIENT, field::CLI, "agent_type"]) else {
            continue;
        };
        let Some(ts) = string_field(&event, &[field::TS]) else {
            continue;
        };
        let parsed_ts = parse_iso_ts(ts)
            .ok_or_else(|| format!("invalid timestamp at line {}: {ts}", index + 1))?;
        let Some(hook) = string_field(&event, &[field::HOOK]) else {
            continue;
        };
        let Some(outcome) = string_field(&event, &[field::DECISION, field::STATUS]) else {
            continue;
        };
        if latest
            .get(client)
            .is_some_and(|(latest_ts, _)| *latest_ts > parsed_ts)
        {
            continue;
        }
        latest.insert(
            client.to_string(),
            (
                parsed_ts,
                (
                    client.to_string(),
                    ts.to_string(),
                    hook.to_string(),
                    outcome.to_string(),
                ),
            ),
        );
    }
    Ok(latest.into_values().map(|(_, event)| event).collect())
}

fn string_field<'a>(event: &'a Value, names: &[&str]) -> Option<&'a str> {
    names
        .iter()
        .find_map(|name| event.get(name).and_then(Value::as_str))
        .filter(|value| !value.is_empty())
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
    for (client, ts, hook, outcome) in latest_client_events(stdin.lock())? {
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

    #[test]
    fn uses_identity_fallbacks_and_latest_timestamp() {
        let input = std::io::Cursor::new(concat!(
            "{\"client\":\"claude\",\"ts\":\"2026-08-31T08:00:00Z\",\"hook\":\"older\",\"decision\":\"pass\"}\n",
            "{\"client\":\"claude\",\"ts\":\"2026-08-31T10:00:00Z\",\"hook\":\"newer\",\"decision\":\"warn\"}\n",
            "{\"cli\":\"codex\",\"ts\":\"2026-08-31T09:00:00Z\",\"hook\":\"codex-hook\",\"status\":\"pass\"}\n",
            "{\"agent_type\":\"gemini\",\"ts\":\"2026-08-31T07:00:00Z\",\"hook\":\"gemini-hook\",\"decision\":\"block\"}\n",
            "{\"client\":\"claude\",\"hook\":\"missing-ts\",\"decision\":\"pass\"}\n",
            "{\"ts\":\"2026-08-31T11:00:00Z\",\"hook\":\"missing-client\",\"decision\":\"pass\"}\n",
        ));

        assert_eq!(
            latest_client_events(input).expect("valid JSONL should stream"),
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
        let error = latest_client_events(input).expect_err("malformed JSONL must fail");
        assert!(error.to_string().contains("line 2"));
    }

    #[test]
    fn ignores_records_missing_hook_or_outcome() {
        let input = std::io::Cursor::new(concat!(
            "{\"client\":\"claude\",\"ts\":\"2026-08-31T08:00:00Z\",\"hook\":\"pre-bash-guard\",\"decision\":\"pass\"}\n",
            "{\"client\":\"claude\",\"ts\":\"2026-08-31T09:00:00Z\",\"decision\":\"pass\"}\n",
            "{\"client\":\"codex\",\"ts\":\"2026-08-31T10:00:00Z\",\"hook\":\"pre-write-guard\"}\n",
        ));

        assert_eq!(
            latest_client_events(input).expect("valid JSONL should stream"),
            vec![(
                "claude".to_string(),
                "2026-08-31T08:00:00Z".to_string(),
                "pre-bash-guard".to_string(),
                "pass".to_string(),
            )]
        );
    }

    #[test]
    fn rejects_records_with_invalid_timestamps() {
        let input = std::io::Cursor::new(concat!(
            "{\"client\":\"claude\",\"ts\":\"2026-08-31T08:00:00Z\",\"hook\":\"pre-bash-guard\",\"decision\":\"pass\"}\n",
            "{\"client\":\"claude\",\"ts\":\"zzz\",\"hook\":\"pre-write-guard\",\"decision\":\"pass\"}\n",
        ));

        let error = latest_client_events(input).expect_err("invalid timestamps must fail");
        assert!(error.to_string().contains("invalid timestamp at line 2"));
    }

    #[test]
    fn compares_valid_timestamps_by_instant() {
        let input = std::io::Cursor::new(concat!(
            "{\"client\":\"claude\",\"ts\":\"2026-09-01T10:00:00+02:00\",\"hook\":\"older\",\"decision\":\"pass\"}\n",
            "{\"client\":\"claude\",\"ts\":\"2026-09-01T09:00:00Z\",\"hook\":\"newer\",\"decision\":\"block\"}\n",
        ));

        assert_eq!(
            latest_client_events(input).expect("valid offset timestamps should stream"),
            vec![(
                "claude".to_string(),
                "2026-09-01T09:00:00Z".to_string(),
                "newer".to_string(),
                "block".to_string(),
            )]
        );
    }
}
