use harness_core::types::{Thread, ThreadId, Turn};
use std::collections::HashMap;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ThreadError {
    #[error("thread not found: {0}")]
    NotFound(String),
}

/// Manages thread lifecycle: create, list, delete, and turn operations.
pub struct ThreadManager {
    threads: HashMap<String, Thread>,
}

impl ThreadManager {
    pub fn new() -> Self {
        Self {
            threads: HashMap::new(),
        }
    }

    /// Start a new thread and return its ID.
    pub fn start_thread(&mut self, title: &str) -> ThreadId {
        let thread = Thread::new(title);
        let id = thread.id.clone();
        self.threads.insert(id.as_str().to_string(), thread);
        id
    }

    /// List all threads.
    pub fn list_threads(&self) -> Vec<&Thread> {
        self.threads.values().collect()
    }

    /// Delete a thread by ID.
    pub fn delete_thread(&mut self, id: &str) -> Result<(), ThreadError> {
        self.threads
            .remove(id)
            .map(|_| ())
            .ok_or_else(|| ThreadError::NotFound(id.to_string()))
    }

    /// Start a new turn in the given thread.
    pub fn start_turn(
        &mut self,
        thread_id: &str,
        user_message: &str,
    ) -> Result<String, ThreadError> {
        let thread = self
            .threads
            .get_mut(thread_id)
            .ok_or_else(|| ThreadError::NotFound(thread_id.to_string()))?;
        let turn = Turn::new(user_message);
        let turn_id = turn.id.clone();
        thread.turns.push(turn);
        thread.updated_at = chrono::Utc::now();
        Ok(turn_id)
    }
}

impl Default for ThreadManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn start_thread_creates_thread() {
        let mut mgr = ThreadManager::new();
        let id = mgr.start_thread("session-1");
        let threads = mgr.list_threads();
        assert_eq!(threads.len(), 1);
        assert_eq!(threads[0].id, id);
        assert_eq!(threads[0].title, "session-1");
    }

    #[test]
    fn list_threads_returns_all() {
        let mut mgr = ThreadManager::new();
        mgr.start_thread("a");
        mgr.start_thread("b");
        mgr.start_thread("c");
        assert_eq!(mgr.list_threads().len(), 3);
    }

    #[test]
    fn delete_thread_removes() {
        let mut mgr = ThreadManager::new();
        let id = mgr.start_thread("to-delete");
        assert_eq!(mgr.list_threads().len(), 1);

        mgr.delete_thread(id.as_str()).expect("delete should succeed");
        assert_eq!(mgr.list_threads().len(), 0);

        let err = mgr.delete_thread(id.as_str());
        assert!(err.is_err());
    }

    #[test]
    fn start_turn_adds_turn_with_user_message() {
        let mut mgr = ThreadManager::new();
        let thread_id = mgr.start_thread("interactive");
        let turn_id = mgr
            .start_turn(thread_id.as_str(), "hello agent")
            .expect("start turn");

        let threads = mgr.list_threads();
        let thread = threads
            .iter()
            .find(|t| t.id == thread_id)
            .expect("thread exists");
        assert_eq!(thread.turns.len(), 1);
        assert_eq!(thread.turns[0].id, turn_id);
        assert_eq!(thread.turns[0].items[0].content, "hello agent");
        assert_eq!(thread.turns[0].items[0].kind, "user_message");
    }
}
