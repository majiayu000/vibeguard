use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::fmt;
use uuid::Uuid;

/// Unique identifier for a thread.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ThreadId(String);

impl ThreadId {
    pub fn new() -> Self {
        Self(Uuid::new_v4().to_string())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Default for ThreadId {
    fn default() -> Self {
        Self::new()
    }
}

impl fmt::Display for ThreadId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Turn status within a thread.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TurnStatus {
    Pending,
    Running,
    Completed,
    Failed,
}

/// A single typed event within a turn.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Item {
    pub kind: String,
    pub content: String,
    pub timestamp: DateTime<Utc>,
}

impl Item {
    pub fn new(kind: &str, content: &str) -> Self {
        Self {
            kind: kind.to_string(),
            content: content.to_string(),
            timestamp: Utc::now(),
        }
    }
}

/// A unit of agent work initiated by a user action.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Turn {
    pub id: String,
    pub status: TurnStatus,
    pub items: Vec<Item>,
    pub created_at: DateTime<Utc>,
    pub completed_at: Option<DateTime<Utc>>,
}

impl Turn {
    pub fn new(user_message: &str) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            status: TurnStatus::Pending,
            items: vec![Item::new("user_message", user_message)],
            created_at: Utc::now(),
            completed_at: None,
        }
    }

    /// Mark this turn as completed.
    pub fn complete(&mut self) {
        self.status = TurnStatus::Completed;
        self.completed_at = Some(Utc::now());
    }
}

/// Persistent session container supporting reconnection.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Thread {
    pub id: ThreadId,
    pub title: String,
    pub turns: Vec<Turn>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl Thread {
    pub fn new(title: &str) -> Self {
        let now = Utc::now();
        Self {
            id: ThreadId::new(),
            title: title.to_string(),
            turns: Vec::new(),
            created_at: now,
            updated_at: now,
        }
    }
}

/// Quality grade derived from a numeric score.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Grade {
    A,
    B,
    C,
    D,
}

impl Grade {
    /// Convert a 0-100 score to a grade.
    pub fn from_score(score: u32) -> Self {
        match score {
            90..=100 => Grade::A,
            70..=89 => Grade::B,
            50..=69 => Grade::C,
            _ => Grade::D,
        }
    }
}

impl fmt::Display for Grade {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Grade::A => write!(f, "A"),
            Grade::B => write!(f, "B"),
            Grade::C => write!(f, "C"),
            Grade::D => write!(f, "D"),
        }
    }
}

/// Signal types emitted by the system.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Signal {
    Warning { message: String },
    Block { rule: String, file: String },
    Info { message: String },
}

/// Event record for observability.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Event {
    pub kind: String,
    pub message: String,
    pub timestamp: DateTime<Utc>,
    pub metadata: serde_json::Value,
}

impl Event {
    pub fn new(kind: &str, message: &str) -> Self {
        Self {
            kind: kind.to_string(),
            message: message.to_string(),
            timestamp: Utc::now(),
            metadata: serde_json::Value::Null,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn thread_id_generates_unique_ids() {
        let mut ids = HashSet::new();
        for _ in 0..100 {
            let id = ThreadId::new();
            assert!(ids.insert(id.as_str().to_string()), "duplicate id generated");
        }
        assert_eq!(ids.len(), 100);
    }

    #[test]
    fn thread_new_initializes_correctly() {
        let thread = Thread::new("test session");
        assert_eq!(thread.title, "test session");
        assert!(thread.turns.is_empty());
        assert!(thread.created_at <= Utc::now());
        assert_eq!(thread.created_at, thread.updated_at);
    }

    #[test]
    fn turn_complete_sets_status_and_completed_at() {
        let mut turn = Turn::new("hello");
        assert_eq!(turn.status, TurnStatus::Pending);
        assert!(turn.completed_at.is_none());

        turn.complete();
        assert_eq!(turn.status, TurnStatus::Completed);
        assert!(turn.completed_at.is_some());
        assert!(turn.completed_at.expect("should be set") >= turn.created_at);
    }

    #[test]
    fn grade_from_score_returns_correct_grades() {
        assert_eq!(Grade::from_score(100), Grade::A);
        assert_eq!(Grade::from_score(95), Grade::A);
        assert_eq!(Grade::from_score(90), Grade::A);
        assert_eq!(Grade::from_score(89), Grade::B);
        assert_eq!(Grade::from_score(70), Grade::B);
        assert_eq!(Grade::from_score(69), Grade::C);
        assert_eq!(Grade::from_score(50), Grade::C);
        assert_eq!(Grade::from_score(49), Grade::D);
        assert_eq!(Grade::from_score(0), Grade::D);
    }

    #[test]
    fn event_signal_item_serde_round_trip() {
        // Event round-trip
        let event = Event::new("build", "compilation succeeded");
        let json = serde_json::to_string(&event).expect("serialize event");
        let decoded: Event = serde_json::from_str(&json).expect("deserialize event");
        assert_eq!(decoded.kind, "build");
        assert_eq!(decoded.message, "compilation succeeded");

        // Signal round-trip
        let signal = Signal::Block {
            rule: "RS-03".to_string(),
            file: "main.rs".to_string(),
        };
        let json = serde_json::to_string(&signal).expect("serialize signal");
        let decoded: Signal = serde_json::from_str(&json).expect("deserialize signal");
        assert_eq!(decoded, signal);

        // Item round-trip
        let item = Item::new("tool_call", "cargo test");
        let json = serde_json::to_string(&item).expect("serialize item");
        let decoded: Item = serde_json::from_str(&json).expect("deserialize item");
        assert_eq!(decoded.kind, "tool_call");
        assert_eq!(decoded.content, "cargo test");
    }
}
