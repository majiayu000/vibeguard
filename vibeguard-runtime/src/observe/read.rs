use serde_json::Value;
use std::collections::VecDeque;
use std::env;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use crate::event_schema::field;
use crate::log_scope::{LogScopeOptions, resolve_log_file};
use crate::time_utils::parse_iso_ts;

use super::Result;
use super::model::ObserveOptions;

pub(super) struct LogEvents {
    pub(super) events: Vec<Value>,
    pub(super) log_path: String,
    pub(super) source_exists: bool,
}

pub(super) fn read_log_events(options: &ObserveOptions) -> Result<LogEvents> {
    let resolved = if let Some(path) = &options.log_file {
        path.clone()
    } else {
        resolve_log_file(&LogScopeOptions {
            scope: options.scope,
            project: options.project.clone(),
            log_file: None,
            allow_env_log_file: !options.scope_explicit && options.project.is_none(),
        })?
        .path
    };
    let log_path = observe_display_path(&resolved);
    if !resolved.exists() {
        if options.log_file.is_some() && !options.legacy {
            return Err(format!("Log file does not exist: {}", resolved.display()).into());
        }
        return Ok(LogEvents {
            events: Vec::new(),
            log_path,
            source_exists: false,
        });
    }
    Ok(LogEvents {
        events: read_jsonl_file_limited(&resolved, options.limit)?,
        log_path,
        source_exists: true,
    })
}

pub(super) fn event_passes_time_window(event: &Value, cutoff_secs: Option<u64>) -> bool {
    let Some(cutoff) = cutoff_secs else {
        return true;
    };
    event
        .get(field::TS)
        .and_then(Value::as_str)
        .and_then(parse_iso_ts)
        .is_some_and(|ts| ts >= cutoff)
}

fn read_jsonl_file_limited(path: &Path, limit: usize) -> Result<Vec<Value>> {
    let file = File::open(path)?;
    let mut reader = BufReader::new(file);
    let mut buf = Vec::new();
    let mut values: VecDeque<Value> = VecDeque::with_capacity(limit.min(1024));
    loop {
        buf.clear();
        match reader.read_until(b'\n', &mut buf)? {
            0 => break,
            _ => {
                let line = String::from_utf8_lossy(&buf);
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                let Ok(value) = serde_json::from_str::<Value>(line) else {
                    continue;
                };
                if !value.is_object() {
                    continue;
                }
                if values.len() == limit {
                    values.pop_front();
                }
                values.push_back(value);
            }
        }
    }
    Ok(values.into_iter().collect())
}

fn observe_display_path(path: &Path) -> String {
    if let Ok(home) = env::var("HOME") {
        let home_path = PathBuf::from(home);
        if let Ok(stripped) = path.strip_prefix(&home_path) {
            return format!("~/{}", stripped.to_string_lossy());
        }
    }
    path.to_string_lossy().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn read_jsonl_file_limited_skips_non_object_records() {
        let nanos = match SystemTime::now().duration_since(UNIX_EPOCH) {
            Ok(duration) => duration.as_nanos(),
            Err(error) => panic!("system time should be after unix epoch: {error}"),
        };
        let path = std::env::temp_dir().join(format!("vibeguard-observe-read-{}.jsonl", nanos));
        if let Err(error) = fs::write(
            &path,
            concat!(
                "{\"hook\":\"pre-bash-guard\"}\n",
                "null\n",
                "[]\n",
                "\"quoted fragment\"\n",
                "{\"hook\":\"post-edit-guard\"}\n"
            ),
        ) {
            panic!("test log should be writable: {error}");
        }

        let events = match read_jsonl_file_limited(&path, usize::MAX) {
            Ok(events) => events,
            Err(error) => panic!("test log should read: {error}"),
        };
        fs::remove_file(&path).ok();

        assert_eq!(events.len(), 2);
        assert_eq!(
            events[0].get(field::HOOK).and_then(Value::as_str),
            Some("pre-bash-guard")
        );
        assert_eq!(
            events[1].get(field::HOOK).and_then(Value::as_str),
            Some("post-edit-guard")
        );
    }
}
