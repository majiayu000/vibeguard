use harness_core::types::Event;
use std::fs;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
}

/// Append-only event store backed by a JSONL file.
pub struct EventStore {
    path: PathBuf,
}

impl EventStore {
    pub fn new(dir: &Path) -> Self {
        Self {
            path: dir.join("events.jsonl"),
        }
    }

    /// Log an event to the store.
    pub fn log(&self, event: &Event) -> Result<(), StoreError> {
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        let mut line = serde_json::to_string(event)?;
        line.push('\n');
        file.write_all(line.as_bytes())?;
        Ok(())
    }

    /// Query all events from the store.
    pub fn query_all(&self) -> Result<Vec<Event>, StoreError> {
        if !self.path.exists() {
            return Ok(Vec::new());
        }
        let file = fs::File::open(&self.path)?;
        let reader = io::BufReader::new(file);
        let mut events = Vec::new();
        for line in reader.lines() {
            let line = line?;
            if line.trim().is_empty() {
                continue;
            }
            let event: Event = serde_json::from_str(&line)?;
            events.push(event);
        }
        Ok(events)
    }

    /// Query events filtered by kind.
    pub fn query_by_kind(&self, kind: &str) -> Result<Vec<Event>, StoreError> {
        let all = self.query_all()?;
        Ok(all.into_iter().filter(|e| e.kind == kind).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn log_and_query_round_trip() {
        let dir = tempfile::tempdir().expect("create tempdir");
        let store = EventStore::new(dir.path());

        let event1 = Event::new("build", "cargo build succeeded");
        let event2 = Event::new("test", "cargo test passed");
        store.log(&event1).expect("log event1");
        store.log(&event2).expect("log event2");

        let all = store.query_all().expect("query all");
        assert_eq!(all.len(), 2);
        assert_eq!(all[0].kind, "build");
        assert_eq!(all[1].kind, "test");
    }

    #[test]
    fn query_with_filters() {
        let dir = tempfile::tempdir().expect("create tempdir");
        let store = EventStore::new(dir.path());

        store.log(&Event::new("build", "ok")).expect("log");
        store.log(&Event::new("test", "ok")).expect("log");
        store.log(&Event::new("build", "rebuild")).expect("log");

        let builds = store.query_by_kind("build").expect("filter");
        assert_eq!(builds.len(), 2);
        assert!(builds.iter().all(|e| e.kind == "build"));

        let tests = store.query_by_kind("test").expect("filter");
        assert_eq!(tests.len(), 1);
    }
}
