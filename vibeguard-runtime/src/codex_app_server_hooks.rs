use crate::codex_app_server_policy::{
    HookPolicyDecision, evaluate_hook_policy, required_hook_missing_message,
};
use crate::project_config::{load_project_config, project_config_path, project_config_root};
use crate::project_config_scoped_suppression::{
    ScopedSuppression, scoped_suppression_matches_output,
};
use crate::runtime_policy::apply_scoped_suppression_value;
use serde_json::Value;
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(Debug, Clone)]
pub struct HookResult {
    pub decision: String,
    pub output: String,
    pub payloads: Vec<Value>,
    pub reason: Option<String>,
    pub updated_command: Option<String>,
    pub failed: bool,
}

impl HookResult {
    pub fn pass() -> Self {
        Self {
            decision: "pass".into(),
            output: String::new(),
            payloads: Vec::new(),
            reason: None,
            updated_command: None,
            failed: false,
        }
    }

    pub fn hook_error(output: impl Into<String>) -> Self {
        Self {
            decision: "hook_error".into(),
            output: output.into(),
            payloads: Vec::new(),
            reason: None,
            updated_command: None,
            failed: true,
        }
    }

    pub fn skip(reason: impl Into<String>) -> Self {
        Self {
            decision: "skip".into(),
            output: String::new(),
            payloads: Vec::new(),
            reason: Some(reason.into()),
            updated_command: None,
            failed: false,
        }
    }
}

#[derive(Debug, Clone)]
pub struct HookRunner {
    hooks_dir: PathBuf,
}

impl HookRunner {
    pub fn new(repo_dir: impl AsRef<Path>) -> Self {
        Self {
            hooks_dir: repo_dir.as_ref().join("hooks"),
        }
    }

    pub fn run(
        &self,
        hook_name: &str,
        payload: &Value,
        cwd: Option<&str>,
        env_overrides: &HashMap<String, String>,
    ) -> HookResult {
        let hook_path = self.hooks_dir.join(hook_name);
        let warn_mode = match evaluate_hook_policy(hook_name, cwd, env_overrides) {
            HookPolicyDecision::Run { warn_mode, .. } => warn_mode,
            HookPolicyDecision::Skip(reason) => return HookResult::skip(reason),
            HookPolicyDecision::Error(reason) => return HookResult::hook_error(reason),
        };
        if !hook_path.is_file() {
            if let Some(reason) = required_hook_missing_message(hook_name, &hook_path) {
                return HookResult::hook_error(reason);
            }
            return HookResult::pass();
        }

        let mut cmd = Command::new("bash");
        cmd.arg(&hook_path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(dir) = cwd {
            cmd.current_dir(dir);
        }
        for (key, value) in env_overrides {
            cmd.env(key, value);
        }

        let mut child = match cmd.spawn() {
            Ok(child) => child,
            Err(e) => {
                eprintln!(
                    "[vibeguard-codex-wrapper] hook {hook_name} failed to launch (cwd={cwd:?} unavailable): {e}"
                );
                return HookResult::hook_error(e.to_string());
            }
        };
        if let Some(mut stdin) = child.stdin.take()
            && let Err(e) = stdin.write_all(payload.to_string().as_bytes())
        {
            return HookResult::hook_error(e.to_string());
        }

        let output = match child.wait_with_output() {
            Ok(output) => output,
            Err(e) => return HookResult::hook_error(e.to_string()),
        };
        let mut text = String::from_utf8_lossy(&output.stdout).to_string();
        if !output.stderr.is_empty() {
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(&String::from_utf8_lossy(&output.stderr));
        }
        let stripped = text.trim().to_string();
        let payloads = extract_payloads(&text);

        if !output.status.success() {
            return HookResult {
                decision: "hook_error".into(),
                output: if stripped.is_empty() {
                    format!(
                        "hook failed with exit {}",
                        output.status.code().unwrap_or(1)
                    )
                } else {
                    stripped
                },
                payloads,
                reason: None,
                updated_command: None,
                failed: true,
            };
        }
        if !stripped.is_empty() && payloads.is_empty() {
            return HookResult::hook_error(format!("hook produced invalid JSON: {stripped}"));
        }

        let decision = payloads
            .iter()
            .find_map(|v| string_field(v, "decision"))
            .unwrap_or_else(|| "pass".into());
        let reason = payloads.iter().find_map(|v| string_field(v, "reason"));
        let updated_command = if decision == "allow" {
            payloads.iter().find_map(extract_updated_command)
        } else {
            None
        };

        let mut result = HookResult {
            decision,
            output: stripped,
            payloads,
            reason,
            updated_command,
            failed: false,
        };
        let scoped_suppression_applied =
            apply_scoped_suppressions(hook_name, cwd, env_overrides, &mut result, payload);
        if !scoped_suppression_applied && warn_mode {
            downgrade_to_warn(&mut result);
        }
        result
    }
}

fn apply_scoped_suppressions(
    hook_name: &str,
    cwd: Option<&str>,
    env_overrides: &HashMap<String, String>,
    result: &mut HookResult,
    payload: &Value,
) -> bool {
    let Some(config_path) = project_config_path(cwd, env_overrides) else {
        return false;
    };
    let project_root = project_config_root(&config_path);
    let Ok(config) = load_project_config(&config_path) else {
        return false;
    };
    apply_matching_scoped_suppressions(
        hook_name,
        result,
        payload,
        project_root.as_deref(),
        &config.scoped_suppressions,
    )
}

fn apply_matching_scoped_suppressions(
    hook_name: &str,
    result: &mut HookResult,
    payload: &Value,
    project_root: Option<&str>,
    suppressions: &[ScopedSuppression],
) -> bool {
    let mut changed = false;
    for output in &mut result.payloads {
        if let Some(suppression) = suppressions.iter().find(|suppression| {
            scoped_suppression_matches_output(
                suppression,
                hook_name,
                output,
                Some(payload),
                project_root,
            )
        }) {
            apply_scoped_suppression_value(output, suppression);
            changed = true;
        }
    }
    if changed {
        recompute_result_from_payloads(result);
    }
    changed
}

fn recompute_result_from_payloads(result: &mut HookResult) {
    result.output = serialize_hook_payloads(&result.payloads);
    result.decision = aggregate_decision(&result.payloads);
    result.updated_command = if result.decision == "allow" {
        result.payloads.iter().find_map(extract_updated_command)
    } else {
        None
    };
    result.reason = aggregate_reason(&result.payloads, &result.decision);
}

fn aggregate_decision(payloads: &[Value]) -> String {
    let decisions = payloads
        .iter()
        .filter_map(|payload| string_field(payload, "decision"))
        .collect::<Vec<_>>();
    for decision in ["hook_error", "block", "gate", "escalate"] {
        if decisions.iter().any(|value| value == decision) {
            return decision.to_string();
        }
    }
    for decision in ["warn", "allow", "skip"] {
        if decisions.iter().any(|value| value == decision) {
            return decision.to_string();
        }
    }
    decisions
        .into_iter()
        .next()
        .unwrap_or_else(|| "pass".into())
}

fn aggregate_reason(payloads: &[Value], aggregate_decision: &str) -> Option<String> {
    if aggregate_decision == "pass" {
        return None;
    }
    let matches_aggregate = |decision: &str| match aggregate_decision {
        "hook_error" | "block" | "gate" | "escalate" => {
            matches!(decision, "hook_error" | "block" | "gate" | "escalate")
        }
        "warn" => decision == "warn",
        other => decision == other,
    };
    payloads
        .iter()
        .filter(|payload| {
            string_field(payload, "decision")
                .as_deref()
                .is_some_and(matches_aggregate)
        })
        .find_map(|payload| string_field(payload, "reason"))
        .or_else(|| {
            payloads
                .iter()
                .find_map(|payload| string_field(payload, "reason"))
        })
}

fn serialize_hook_payloads(payloads: &[Value]) -> String {
    payloads
        .iter()
        .filter_map(|payload| serde_json::to_string(payload).ok())
        .collect::<Vec<_>>()
        .join("\n")
}

fn downgrade_to_warn(result: &mut HookResult) {
    if result.failed || result.decision == "hook_error" {
        return;
    }
    if !matches!(result.decision.as_str(), "block" | "gate" | "escalate") {
        return;
    }

    result.decision = "warn".into();
    result.updated_command = None;
    result.reason = Some(
        match result.reason.as_deref().filter(|reason| !reason.is_empty()) {
            Some(reason) => format!("VIBEGUARD warn-mode advisory: {reason}"),
            None => {
                "VIBEGUARD warn-mode advisory: hook result downgraded by project enforcement=warn"
                    .into()
            }
        },
    );
}

fn extract_payloads(output: &str) -> Vec<Value> {
    let mut payloads = Vec::new();
    let stripped = output.trim();
    if stripped.is_empty() {
        return payloads;
    }

    let mut candidates = vec![stripped.to_string()];
    candidates.extend(
        output
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(str::to_string),
    );

    let mut seen = std::collections::HashSet::new();
    for candidate in candidates {
        if !seen.insert(candidate.clone()) {
            continue;
        }
        if let Ok(value) = serde_json::from_str::<Value>(&candidate)
            && value.is_object()
        {
            payloads.push(value);
        }
    }
    payloads
}

fn extract_updated_command(payload: &Value) -> Option<String> {
    payload
        .get("updatedInput")
        .and_then(|v| v.get("command"))
        .and_then(Value::as_str)
        .map(str::to_string)
}

fn string_field(value: &Value, field: &str) -> Option<String> {
    value.get(field).and_then(Value::as_str).map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_payloads_deduplicates_full_and_line_json() {
        let output = "{\"decision\":\"block\"}\n";
        let payloads = extract_payloads(output);
        assert_eq!(payloads.len(), 1);
        assert_eq!(payloads[0]["decision"], "block");
    }

    #[test]
    fn scoped_suppression_rewrites_only_matching_payloads() {
        let suppression = ScopedSuppression {
            hook: "post-edit-guard".to_string(),
            rule_id: "RS-03".to_string(),
            path: "docs/examples/**".to_string(),
            code: None,
            action: "suppress".to_string(),
            reason: "Known docs example false positive".to_string(),
            expires_at: None,
        };
        let hook_payload = serde_json::json!({
            "tool_input": {"file_path": "/repo/docs/examples/basic.rs"}
        });
        let mut result = HookResult {
            decision: "block".to_string(),
            output: String::new(),
            payloads: vec![
                serde_json::json!({
                    "decision": "block",
                    "hookSpecificOutput": {
                        "hookEventName": "PostToolUse",
                        "additionalContext": "VIBEGUARD quality warning: [RS-03] unwrap should be hidden"
                    }
                }),
                serde_json::json!({
                    "decision": "block",
                    "rule_id": "RS-10",
                    "path": "docs/examples/basic.rs",
                    "reason": "RS-10 still blocks"
                }),
            ],
            reason: Some("original block".to_string()),
            updated_command: None,
            failed: false,
        };

        assert!(apply_matching_scoped_suppressions(
            "post-edit-guard.sh",
            &mut result,
            &hook_payload,
            Some("/repo"),
            &[suppression],
        ));

        assert_eq!(result.payloads[0]["decision"], "pass");
        assert!(result.payloads[0].get("hookSpecificOutput").is_none());
        assert_eq!(result.payloads[1]["decision"], "block");
        assert_eq!(result.decision, "block");
        assert_eq!(result.reason.as_deref(), Some("RS-10 still blocks"));
        assert!(result.output.contains("RS-10 still blocks"));
        assert!(!result.output.contains("unwrap should be hidden"));
    }
}
