//! Stable, core-only classifier entry points for microbenchmarks.
//!
//! These functions intentionally avoid hook wrappers, process startup, stdin/stdout
//! protocol adaptation, config discovery, event-log I/O, and logging.

use crate::hook_checks_bash::{self, BashDecisionKind};
use crate::hook_checks_common;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BashCommandClassification {
    Empty,
    Pass,
    Block,
    Warn,
    Correction,
}

pub fn classify_bash_command(command: &str, vibeguard_root: &str) -> BashCommandClassification {
    match hook_checks_bash::classify_command_kind(command, vibeguard_root) {
        BashDecisionKind::Empty => BashCommandClassification::Empty,
        BashDecisionKind::Pass => BashCommandClassification::Pass,
        BashDecisionKind::Block => BashCommandClassification::Block,
        BashDecisionKind::Warn => BashCommandClassification::Warn,
        BashDecisionKind::Correction => BashCommandClassification::Correction,
    }
}

pub fn classify_clean_rust_write(file_path: &str, content: &str, base_limit: usize) -> bool {
    hook_checks_common::is_clean_rust_write_fast_path(file_path, content, base_limit)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bash_classifier_reports_core_decision_kind() {
        assert_eq!(
            classify_bash_command("git restore .", "/repo"),
            BashCommandClassification::Block
        );
        assert_eq!(
            classify_bash_command("npm install", "/repo"),
            BashCommandClassification::Correction
        );
    }

    #[test]
    fn write_classifier_exposes_pure_fast_path() {
        assert!(classify_clean_rust_write(
            "src/new_file.rs",
            "let value = 1;\nlet doubled = value * 2;\n",
            800
        ));
        assert!(!classify_clean_rust_write(
            "src/lib.rs",
            "pub struct PaymentGateway;\n",
            800
        ));
    }
}
