use harness_core::types::Grade;

/// Event kind used for quality grading.
#[derive(Debug, Clone)]
pub struct QualityEvent {
    pub kind: String,
    pub severity: u32,
}

/// Grades quality based on observed events.
pub struct QualityGrader;

impl QualityGrader {
    /// Calculate a quality score from 0-100 based on events.
    /// Empty events = perfect score (100).
    /// Block events reduce the score.
    pub fn grade(events: &[QualityEvent]) -> (u32, Grade) {
        if events.is_empty() {
            return (100, Grade::A);
        }

        let mut deductions: u32 = 0;
        for event in events {
            match event.kind.as_str() {
                "block" => deductions += event.severity * 10,
                "warning" => deductions += event.severity * 3,
                _ => deductions += event.severity,
            }
        }

        let score = 100u32.saturating_sub(deductions);
        let grade = Grade::from_score(score);
        (score, grade)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grade_with_empty_events_returns_100() {
        let (score, grade) = QualityGrader::grade(&[]);
        assert_eq!(score, 100);
        assert_eq!(grade, Grade::A);
    }

    #[test]
    fn grade_with_block_events_returns_lower_score() {
        let events = vec![
            QualityEvent {
                kind: "block".to_string(),
                severity: 3,
            },
            QualityEvent {
                kind: "warning".to_string(),
                severity: 2,
            },
        ];
        let (score, grade) = QualityGrader::grade(&events);
        // deductions: 3*10 + 2*3 = 36, score = 64
        assert_eq!(score, 64);
        assert_eq!(grade, Grade::C);
    }
}
