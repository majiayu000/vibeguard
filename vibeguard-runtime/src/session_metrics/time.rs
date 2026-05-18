use serde_json::Value;

use crate::event_schema::field;
use crate::time_utils;

pub(super) fn now_unix_secs() -> u64 {
    time_utils::now_unix_secs()
}

pub(super) fn parse_iso_ts(ts: &str) -> Option<u64> {
    time_utils::parse_iso_ts(ts)
}

/// Returns true if the event should be included in session metrics.
/// Events whose `ts` field is present but not a parseable ISO-8601 string are
/// excluded to prevent filter bypass from corrupt log lines (including non-string types).
pub(super) fn event_passes_time_filter(e: &Value, cutoff_secs: u64) -> bool {
    match e.get(field::TS) {
        None => true,
        Some(ts_val) => match ts_val.as_str() {
            Some(ts) => match parse_iso_ts(ts) {
                Some(evt_secs) => evt_secs >= cutoff_secs,
                None => false,
            },
            None => false,
        },
    }
}

/// Returns true if the event belongs to the given session (or has no session field).
pub(super) fn event_passes_session_filter(evt: &Value, session: &str) -> bool {
    let evt_session = evt
        .get(field::SESSION)
        .and_then(Value::as_str)
        .unwrap_or("");
    evt_session.is_empty() || evt_session == session
}

pub(super) fn chrono_now() -> String {
    time_utils::format_unix_secs_utc(now_unix_secs())
}
