//! Session metrics collection + correction signal detection.
//! Canonical implementation. hooks/_lib/session_metrics.py is a deprecated fallback.

mod engine;
mod signals;
mod time;

#[cfg(test)]
mod tests;

pub use engine::run;

#[cfg(test)]
use engine::run_inner;
#[cfg(test)]
use time::{event_passes_session_filter, event_passes_time_filter, now_unix_secs, parse_iso_ts};
