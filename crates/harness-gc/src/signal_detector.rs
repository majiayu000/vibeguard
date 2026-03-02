use harness_rules::engine::Violation;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// A GC signal indicating cleanup is needed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GcSignal {
    RepeatedWarnings {
        rule: String,
        count: usize,
    },
    ChronicBlocks {
        file: String,
        count: usize,
    },
    HotFile {
        file: String,
        violation_count: usize,
    },
}

/// Detect GC signals from a list of violations.
pub struct SignalDetector {
    warn_threshold: usize,
    block_threshold: usize,
    hot_file_threshold: usize,
}

impl SignalDetector {
    pub fn new(warn_threshold: usize, block_threshold: usize, hot_file_threshold: usize) -> Self {
        Self {
            warn_threshold,
            block_threshold,
            hot_file_threshold,
        }
    }

    /// Detect repeated warnings: same rule appearing above threshold.
    pub fn detect_repeated_warns(&self, violations: &[Violation]) -> Vec<GcSignal> {
        let mut rule_counts: HashMap<&str, usize> = HashMap::new();
        for v in violations {
            *rule_counts.entry(&v.rule).or_insert(0) += 1;
        }
        rule_counts
            .into_iter()
            .filter(|(_, count)| *count >= self.warn_threshold)
            .map(|(rule, count)| GcSignal::RepeatedWarnings {
                rule: rule.to_string(),
                count,
            })
            .collect()
    }

    /// Detect chronic blocks: same file blocked repeatedly.
    pub fn detect_chronic_blocks(&self, violations: &[Violation]) -> Vec<GcSignal> {
        let mut file_counts: HashMap<&str, usize> = HashMap::new();
        for v in violations {
            *file_counts.entry(&v.file).or_insert(0) += 1;
        }
        file_counts
            .into_iter()
            .filter(|(_, count)| *count >= self.block_threshold)
            .map(|(file, count)| GcSignal::ChronicBlocks {
                file: file.to_string(),
                count,
            })
            .collect()
    }

    /// Detect hot files: files with many violations.
    pub fn detect_hot_files(&self, violations: &[Violation]) -> Vec<GcSignal> {
        let mut file_counts: HashMap<&str, usize> = HashMap::new();
        for v in violations {
            *file_counts.entry(&v.file).or_insert(0) += 1;
        }
        file_counts
            .into_iter()
            .filter(|(_, count)| *count >= self.hot_file_threshold)
            .map(|(file, count)| GcSignal::HotFile {
                file: file.to_string(),
                violation_count: count,
            })
            .collect()
    }

    /// Run all detectors and return combined signals.
    pub fn from_violations(&self, violations: &[Violation]) -> Vec<GcSignal> {
        let mut signals = Vec::new();
        signals.extend(self.detect_repeated_warns(violations));
        signals.extend(self.detect_chronic_blocks(violations));
        signals.extend(self.detect_hot_files(violations));
        signals
    }
}

impl Default for SignalDetector {
    fn default() -> Self {
        Self::new(3, 3, 5)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_violation(file: &str, rule: &str) -> Violation {
        Violation {
            file: file.to_string(),
            line: 1,
            rule: rule.to_string(),
            message: "test".to_string(),
        }
    }

    #[test]
    fn detect_repeated_warns_above_threshold() {
        let detector = SignalDetector::new(2, 10, 10);
        let violations = vec![
            make_violation("a.rs", "RS-03"),
            make_violation("b.rs", "RS-03"),
            make_violation("c.rs", "RS-03"),
            make_violation("d.rs", "RS-01"),
        ];
        let signals = detector.detect_repeated_warns(&violations);
        assert_eq!(signals.len(), 1);
        match &signals[0] {
            GcSignal::RepeatedWarnings { rule, count } => {
                assert_eq!(rule, "RS-03");
                assert_eq!(*count, 3);
            }
            other => panic!("expected RepeatedWarnings, got {:?}", other),
        }
    }

    #[test]
    fn detect_chronic_blocks() {
        let detector = SignalDetector::new(10, 2, 10);
        let violations = vec![
            make_violation("main.rs", "RS-01"),
            make_violation("main.rs", "RS-03"),
            make_violation("main.rs", "RS-05"),
            make_violation("lib.rs", "RS-01"),
        ];
        let signals = detector.detect_chronic_blocks(&violations);
        assert_eq!(signals.len(), 1);
        match &signals[0] {
            GcSignal::ChronicBlocks { file, count } => {
                assert_eq!(file, "main.rs");
                assert_eq!(*count, 3);
            }
            other => panic!("expected ChronicBlocks, got {:?}", other),
        }
    }

    #[test]
    fn detect_hot_files() {
        let detector = SignalDetector::new(10, 10, 2);
        let violations = vec![
            make_violation("hot.rs", "RS-01"),
            make_violation("hot.rs", "RS-02"),
            make_violation("hot.rs", "RS-03"),
            make_violation("cool.rs", "RS-01"),
        ];
        let signals = detector.detect_hot_files(&violations);
        assert_eq!(signals.len(), 1);
        match &signals[0] {
            GcSignal::HotFile {
                file,
                violation_count,
            } => {
                assert_eq!(file, "hot.rs");
                assert_eq!(*violation_count, 3);
            }
            other => panic!("expected HotFile, got {:?}", other),
        }
    }

    #[test]
    fn from_violations_combines_all_signals() {
        let detector = SignalDetector::new(2, 2, 3);
        let violations = vec![
            make_violation("f.rs", "RS-03"),
            make_violation("f.rs", "RS-03"),
            make_violation("f.rs", "RS-01"),
        ];
        let signals = detector.from_violations(&violations);
        // RS-03 repeated 2x (hits warn threshold)
        // f.rs has 3 violations (hits block threshold of 2, and hot_file threshold of 3)
        assert!(signals.len() >= 2);
    }
}
