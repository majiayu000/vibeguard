use serde_json::Value;
use std::collections::HashMap;

use crate::event_schema::{decision, field, metric_field};

fn extract_paralysis_depth(reason: &str) -> Option<u64> {
    reason
        .split_whitespace()
        .filter_map(|part| part.strip_suffix('x'))
        .filter_map(|num| num.parse::<u64>().ok())
        .max()
}

pub(super) fn build_signals(
    events: &[Value],
    decisions: &HashMap<String, u64>,
    edited_files: &HashMap<String, u64>,
    warn_ratio: f64,
    negative: u64,
    project_dir: &str,
) -> Vec<String> {
    let mut signals: Vec<String> = Vec::new();
    // Signal 1: High friction (>25%, >=3)
    if warn_ratio > 0.25 && negative >= 3 {
        signals.push(format!(
            "High friction session: {negative}/{} events ({:.0}%)",
            events.len(),
            warn_ratio * 100.0
        ));
    }

    // Signal 2: File churn (adaptive threshold)
    let distinct = edited_files.values().filter(|&&c| c >= 1).count();
    let thresh: u64 = if distinct >= 5 { 7 } else { 3 };
    let mut top_files: Vec<_> = edited_files.iter().collect();
    top_files.sort_by(|a, b| b.1.cmp(a.1));
    for (f, c) in top_files.iter().take(5) {
        if **c >= thresh {
            let base = f.rsplit('/').next().unwrap_or(f);
            signals.push(format!("{base} edited {c} times (repeated correction)"));
        }
    }

    // Signal 3-4: correction + escalate
    let corr = *decisions.get(decision::CORRECTION).unwrap_or(&0);
    if corr > 0 {
        signals.push(format!("{corr} real-time correction detection triggers"));
    }
    let esc = *decisions.get(decision::ESCALATE).unwrap_or(&0);
    if esc > 0 {
        signals.push(format!("{esc} upgrade warnings"));
    }

    // Signal 5: blocks
    let blocks = *decisions.get(decision::BLOCK).unwrap_or(&0);
    if blocks > 0 {
        let reasons: Vec<String> = events
            .iter()
            .filter(|e| e.get(field::DECISION).and_then(Value::as_str) == Some(decision::BLOCK))
            .filter_map(|e| e.get(field::REASON).and_then(Value::as_str))
            .map(|r| r.chars().take(60).collect())
            .collect();
        let unique: Vec<&String> = {
            let mut seen = Vec::new();
            for r in &reasons {
                if !seen.contains(&r) {
                    seen.push(r);
                }
                if seen.len() >= 3 {
                    break;
                }
            }
            seen
        };
        let joined = unique
            .iter()
            .map(|s| s.as_str())
            .collect::<Vec<_>>()
            .join("; ");
        signals.push(format!("{blocks} block(s): {joined}"));
    }

    // Signal 6: paralysis
    let paralysis: Vec<_> = events
        .iter()
        .filter(|e| {
            e.get(field::REASON)
                .and_then(Value::as_str)
                .is_some_and(|r| r.contains("paralysis"))
        })
        .collect();
    if paralysis.len() >= 2 {
        let max_depth = paralysis
            .iter()
            .filter_map(|e| e.get(field::REASON).and_then(Value::as_str))
            .filter_map(extract_paralysis_depth)
            .max()
            .unwrap_or(0);
        signals.push(format!(
            "Analysis paralysis: {} triggers (max depth {max_depth}x)",
            paralysis.len()
        ));
    }

    // Signal 7: rule repeat (same rule 3+ times)
    let mut rule_counts: HashMap<String, u64> = HashMap::new();
    for e in events {
        let decision_name = e.get(field::DECISION).and_then(Value::as_str).unwrap_or("");
        if !decision::RULE_REPEAT.contains(&decision_name) {
            continue;
        }
        let reason = e.get(field::REASON).and_then(Value::as_str).unwrap_or("");
        if let Some(end) = reason.find(']') {
            let tag = &reason[..=end];
            *rule_counts.entry(tag.into()).or_default() += 1;
        }
    }
    let mut repeat_rules: Vec<_> = rule_counts
        .iter()
        .filter(|(_, count)| **count >= 3)
        .collect();
    repeat_rules.sort_by(|(tag_a, count_a), (tag_b, count_b)| {
        count_b.cmp(count_a).then_with(|| tag_a.cmp(tag_b))
    });
    for (tag, count) in repeat_rules.into_iter().take(3) {
        signals.push(format!("Rule {tag} triggered {count} times (pattern)"));
    }

    // Signal 8: build failure cluster
    let bf = events
        .iter()
        .filter(|e| {
            let r = e.get(field::REASON).and_then(Value::as_str).unwrap_or("");
            let rl = r.to_lowercase();
            r.contains("构建错误") || rl.contains("build fail") || rl.contains("build error")
        })
        .count();
    if bf >= 3 {
        signals.push(format!("{bf} build failures in session (spiral risk)"));
    }

    // Signal 9: circuit breaker trips
    let cb = events
        .iter()
        .filter(|e| {
            e.get(field::REASON)
                .and_then(Value::as_str)
                .is_some_and(|r| r.contains("CB tripped"))
        })
        .count();
    if cb > 0 {
        signals.push(format!("Circuit breaker tripped {cb} time(s)"));
    }

    // Signal 10: warn trend regression vs project baseline
    // Mirrors Python predecessor hooks/_lib/session_metrics.py:166-187
    let metrics_path = format!("{project_dir}/session-metrics.jsonl");
    if let Ok(content) = std::fs::read_to_string(&metrics_path) {
        let recent_ratios: Vec<f64> = content
            .lines()
            .filter(|l| !l.trim().is_empty())
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter_map(|m| m.get(metric_field::WARN_RATIO).and_then(Value::as_f64))
            .filter(|&r| r > 0.0)
            .collect();
        if recent_ratios.len() >= 10 {
            let window: Vec<f64> = recent_ratios.iter().rev().take(20).cloned().collect();
            let baseline = window.iter().sum::<f64>() / window.len() as f64;
            if warn_ratio > baseline * 2.0 && warn_ratio > 0.1 {
                signals.push(format!(
                    "Warn rate regression: {:.0}% vs baseline {:.0}% (2x+)",
                    warn_ratio * 100.0,
                    baseline * 100.0
                ));
            }
        }
    }
    signals
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn decision_counts(entries: &[(&str, u64)]) -> HashMap<String, u64> {
        entries
            .iter()
            .map(|(decision, count)| ((*decision).to_string(), *count))
            .collect()
    }

    #[test]
    fn extracts_max_paralysis_depth_from_reason_text() {
        assert_eq!(extract_paralysis_depth("analysis paralysis 2x 7x"), Some(7));
        assert_eq!(extract_paralysis_depth("analysis paralysis"), None);
    }

    #[test]
    fn build_signals_reports_high_friction() {
        let events = vec![
            json!({"decision": "warn"}),
            json!({"decision": "warn"}),
            json!({"decision": "block"}),
            json!({"decision": "pass"}),
        ];
        let decisions = decision_counts(&[(decision::WARN, 2), (decision::BLOCK, 1)]);
        let edited_files = HashMap::new();

        let signals = build_signals(&events, &decisions, &edited_files, 0.75, 3, "/no/such/dir");

        assert!(
            signals
                .iter()
                .any(|signal| signal.contains("High friction session: 3/4 events"))
        );
    }

    #[test]
    fn build_signals_caps_rule_repeats_to_deterministic_top_three() {
        let mut events = Vec::new();
        for tag in ["U-02", "U-02", "U-02", "U-02"] {
            events.push(json!({"decision": "warn", "reason": format!("[{tag}] repeated")}));
        }
        for tag in [
            "U-01", "U-01", "U-01", "U-03", "U-03", "U-03", "U-04", "U-04", "U-04",
        ] {
            events.push(json!({"decision": "warn", "reason": format!("[{tag}] repeated")}));
        }

        let signals = build_signals(
            &events,
            &HashMap::new(),
            &HashMap::new(),
            0.0,
            0,
            "/no/such/dir",
        );
        let joined = signals.join("\n");
        let u02 = joined.find("Rule [U-02] triggered 4 times").unwrap();
        let u01 = joined.find("Rule [U-01] triggered 3 times").unwrap();
        let u03 = joined.find("Rule [U-03] triggered 3 times").unwrap();

        assert!(u02 < u01 && u01 < u03);
        assert!(!joined.contains("Rule [U-04]"));
    }

    #[test]
    fn build_signals_reports_paralysis_max_depth() {
        let events = vec![
            json!({"reason": "analysis paralysis 3x"}),
            json!({"reason": "analysis paralysis 11x"}),
            json!({"reason": "ordinary event"}),
        ];

        let signals = build_signals(
            &events,
            &HashMap::new(),
            &HashMap::new(),
            0.0,
            0,
            "/no/such/dir",
        );

        assert!(signals.contains(&"Analysis paralysis: 2 triggers (max depth 11x)".to_string()));
    }
}
