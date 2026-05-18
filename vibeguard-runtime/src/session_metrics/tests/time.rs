use super::super::*;

// --- parse_iso_ts ---

#[test]
fn test_parse_unix_epoch() {
    assert_eq!(parse_iso_ts("1970-01-01T00:00:00Z"), Some(0));
}

#[test]
fn test_parse_z_suffix() {
    // 2024-01-01T00:00:00Z
    // Days from 1970-01-01 to 2024-01-01:
    //   leap years in [1970, 2024): 1972,1976,...,2020 => (2020-1972)/4+1 = 13 leap years
    //   total years = 54, non-leap = 41, leap = 13 => 41*365 + 13*366 = 14965+4758 = 19723 days
    let expected_secs: u64 = 19723 * 86400;
    assert_eq!(parse_iso_ts("2024-01-01T00:00:00Z"), Some(expected_secs));
}

#[test]
fn test_parse_plus00_suffix() {
    assert_eq!(parse_iso_ts("1970-01-01T00:00:00+00:00"), Some(0));
}

#[test]
fn test_parse_with_hms() {
    // 1970-01-01T01:02:03Z = 3600+120+3 = 3723 secs
    assert_eq!(parse_iso_ts("1970-01-01T01:02:03Z"), Some(3723));
}

#[test]
fn test_parse_invalid_returns_none() {
    assert_eq!(parse_iso_ts("not-a-timestamp"), None);
    assert_eq!(parse_iso_ts(""), None);
    assert_eq!(parse_iso_ts("2024-01-01"), None); // missing T separator
}

#[test]
fn test_parse_out_of_range_month_returns_none() {
    // month=13 would index month_days[12] — out of bounds without validation
    assert_eq!(parse_iso_ts("2024-13-01T00:00:00Z"), None);
    assert_eq!(parse_iso_ts("2024-00-01T00:00:00Z"), None);
}

#[test]
fn test_parse_out_of_range_day_returns_none() {
    assert_eq!(parse_iso_ts("2026-04-00T12:00:00Z"), None); // day=0
    assert_eq!(parse_iso_ts("2026-04-31T12:00:00Z"), None); // April has 30 days
    assert_eq!(parse_iso_ts("2026-02-29T12:00:00Z"), None); // 2026 is not a leap year
    assert_eq!(parse_iso_ts("2026-02-31T12:00:00Z"), None); // Feb never has 31 days
    assert!(parse_iso_ts("2024-02-29T12:00:00Z").is_some()); // 2024 is a leap year
}

#[test]
fn test_parse_out_of_range_time_returns_none() {
    assert_eq!(parse_iso_ts("2026-04-18T99:00:00Z"), None); // hour=99
    assert_eq!(parse_iso_ts("2026-04-18T24:00:00Z"), None); // hour=24
    assert_eq!(parse_iso_ts("2026-04-18T00:60:00Z"), None); // min=60
    assert_eq!(parse_iso_ts("2026-04-18T00:00:60Z"), None); // sec=60
    assert_eq!(parse_iso_ts("2026-04-00T99:99:99Z"), None); // day+time all invalid
    // negative time components must also be rejected
    assert_eq!(parse_iso_ts("2026-04-18T-1:00:00Z"), None); // hour=-1
    assert_eq!(parse_iso_ts("2026-04-18T00:-1:00Z"), None); // min=-1
    assert_eq!(parse_iso_ts("2026-04-18T00:00:-1Z"), None); // sec=-1
}

// --- 30-minute time-window filter (via production event_passes_time_filter) ---

#[test]
fn test_event_inside_30min_window_passes() {
    // epoch+60s is inside a window whose cutoff is 0 — must pass
    assert!(
        event_passes_time_filter(&serde_json::json!({"ts": "1970-01-01T00:01:00Z"}), 0),
        "recent event should pass the 30-min filter"
    );
}

#[test]
fn test_event_outside_30min_window_drops() {
    // epoch 0s is before cutoff 60s — must be dropped
    assert!(
        !event_passes_time_filter(&serde_json::json!({"ts": "1970-01-01T00:00:00Z"}), 60),
        "old event should be dropped by 30-min filter"
    );
}

#[test]
fn test_event_exactly_at_cutoff_passes() {
    // epoch 60s == cutoff 60s — must NOT be dropped (strict less-than in production)
    // If the comparison ever regresses to `<=`, this test will fail.
    assert!(
        event_passes_time_filter(&serde_json::json!({"ts": "1970-01-01T00:01:00Z"}), 60),
        "event at exactly the cutoff boundary must not be dropped"
    );
}

// --- event_passes_time_filter (caller-path coverage for issues 1 & 3) ---

#[test]
fn test_malformed_ts_is_excluded_by_filter() {
    // Exercises the caller path: parse_iso_ts(ts)==None must NOT fall through to push.
    let cutoff = now_unix_secs().saturating_sub(30 * 60);
    let e = serde_json::json!({"ts": "not-a-date", "hook": "test"});
    assert!(
        !event_passes_time_filter(&e, cutoff),
        "event with unparseable ts must be excluded, not fall through the 30-min filter"
    );
}

#[test]
fn test_non_string_ts_is_excluded_by_filter() {
    // ts present as number, object, or array — must be excluded, not silently admitted.
    let cutoff = now_unix_secs().saturating_sub(30 * 60);
    assert!(
        !event_passes_time_filter(&serde_json::json!({"ts": 123456789}), cutoff),
        "numeric ts must be excluded"
    );
    assert!(
        !event_passes_time_filter(&serde_json::json!({"ts": {}}), cutoff),
        "object ts must be excluded"
    );
    assert!(
        !event_passes_time_filter(&serde_json::json!({"ts": []}), cutoff),
        "array ts must be excluded"
    );
    assert!(
        !event_passes_time_filter(&serde_json::json!({"ts": null}), cutoff),
        "null ts must be excluded"
    );
}

#[test]
fn test_no_ts_field_passes_filter() {
    // Events with no ts field have no timestamp to validate — include them.
    let cutoff = now_unix_secs().saturating_sub(30 * 60);
    let e = serde_json::json!({"hook": "test"});
    assert!(event_passes_time_filter(&e, cutoff));
}

#[test]
fn test_recent_ts_passes_filter() {
    let now = now_unix_secs();
    let cutoff = now.saturating_sub(30 * 60);
    // 1970-01-01T00:00:00Z = 0 secs — far older than cutoff, should be dropped
    assert!(!event_passes_time_filter(
        &serde_json::json!({"ts": "1970-01-01T00:00:00Z"}),
        cutoff
    ));
    // epoch + cutoff + 60 secs — inside the window, should pass
    // Use a timestamp we know is "recent" relative to a cutoff of 0
    assert!(event_passes_time_filter(
        &serde_json::json!({"ts": "1970-01-01T00:00:00Z"}),
        0
    ));
}

// --- session ID filter (via production event_passes_session_filter) ---

#[test]
fn test_different_session_is_excluded() {
    let e = serde_json::json!({"session": "sess-B", "hook": "test"});
    assert!(
        !event_passes_session_filter(&e, "sess-A"),
        "event from different session must be excluded"
    );
}

#[test]
fn test_same_session_is_included() {
    let e = serde_json::json!({"session": "sess-A", "hook": "test"});
    assert!(
        event_passes_session_filter(&e, "sess-A"),
        "event from same session must be included"
    );
}

#[test]
fn test_missing_session_field_is_included() {
    let e = serde_json::json!({"hook": "test"});
    assert!(
        event_passes_session_filter(&e, "sess-A"),
        "event with no session field must be included"
    );
}
