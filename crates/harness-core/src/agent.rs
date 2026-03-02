use serde::{Deserialize, Serialize};

/// Request payload sent to an agent.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentRequest {
    pub thread_id: String,
    pub turn_id: String,
    pub message: String,
    pub tools: Vec<String>,
}

impl AgentRequest {
    pub fn new(thread_id: &str, turn_id: &str, message: &str) -> Self {
        Self {
            thread_id: thread_id.to_string(),
            turn_id: turn_id.to_string(),
            message: message.to_string(),
            tools: Vec::new(),
        }
    }

    pub fn with_tools(mut self, tools: Vec<String>) -> Self {
        self.tools = tools;
        self
    }
}
