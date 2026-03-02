use serde::{Deserialize, Serialize};

/// A guard violation parsed from linter output.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Violation {
    pub file: String,
    pub line: u32,
    pub rule: String,
    pub message: String,
}

/// Rule engine that manages architectural constraints.
pub struct RuleEngine {
    rules: Vec<String>,
}

impl RuleEngine {
    pub fn new() -> Self {
        Self { rules: Vec::new() }
    }

    pub fn add_rule(&mut self, rule: &str) {
        self.rules.push(rule.to_string());
    }

    pub fn rule_count(&self) -> usize {
        self.rules.len()
    }
}

impl Default for RuleEngine {
    fn default() -> Self {
        Self::new()
    }
}

/// Parse guard output in FILE:LINE:RULE:MSG format.
pub fn parse_guard_output(line: &str) -> Option<Violation> {
    let parts: Vec<&str> = line.splitn(4, ':').collect();
    if parts.len() < 4 {
        return None;
    }
    let line_num = parts[1].trim().parse::<u32>().ok()?;
    Some(Violation {
        file: parts[0].trim().to_string(),
        line: line_num,
        rule: parts[2].trim().to_string(),
        message: parts[3].trim().to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rule_engine_new_is_empty() {
        let engine = RuleEngine::new();
        assert_eq!(engine.rule_count(), 0);

        let mut engine = RuleEngine::new();
        engine.add_rule("RS-01");
        engine.add_rule("RS-03");
        assert_eq!(engine.rule_count(), 2);
    }

    #[test]
    fn parse_guard_output_parses_correctly() {
        let line = "src/main.rs:42:RS-03:unwrap in non-test code";
        let v = parse_guard_output(line).expect("should parse");
        assert_eq!(v.file, "src/main.rs");
        assert_eq!(v.line, 42);
        assert_eq!(v.rule, "RS-03");
        assert_eq!(v.message, "unwrap in non-test code");

        // Invalid format returns None
        assert!(parse_guard_output("no colons here").is_none());
        assert!(parse_guard_output("file:notanum:RULE:msg").is_none());
    }
}
