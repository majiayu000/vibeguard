//! Codex hook protocol helpers used by run-hook-codex.sh.

use crate::hook_checks_common::{read_stdin, truncate_chars};
use serde_json::{Map, Value, json};

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

pub(crate) fn ensure_no_args(args: &[String], usage: &str) -> Result {
    if args.is_empty() {
        Ok(())
    } else {
        Err(usage.into())
    }
}

fn read_json_tolerant() -> std::io::Result<Option<Value>> {
    let input = read_stdin()?;
    Ok(serde_json::from_str(&input).ok())
}

fn codex_event_name(data: &Value) -> &str {
    data.get("hook_event_name")
        .and_then(Value::as_str)
        .unwrap_or("")
}

// Writer identity must come from the logical Codex session, not the wrapper's
// short-lived parent PID (issue #673): pre/post hooks of one Edit can run under
// different parent processes, but they share the payload's top-level session_id.
fn codex_logical_session_id(data: &Value) -> String {
    data.get("session_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(crate::codex_app_server_core::session_id_for_thread)
        .unwrap_or_default()
}

pub fn session_id(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-session-id")?;
    let data = read_json_tolerant()?;
    println!(
        "{}",
        data.as_ref()
            .map(codex_logical_session_id)
            .unwrap_or_default()
    );
    Ok(())
}

fn codex_status_matcher(data: &Value) -> &str {
    data.get("tool_name").and_then(Value::as_str).unwrap_or("")
}

fn codex_status_detail(data: &Value) -> String {
    let Some(tool_input) = data.get("tool_input").and_then(Value::as_object) else {
        return String::new();
    };
    for key in ["file_path", "command"] {
        if let Some(value) = tool_input.get(key).and_then(Value::as_str)
            && !value.is_empty()
        {
            return truncate_chars(value, 300);
        }
    }
    String::new()
}

fn shell_status_field(value: &str) -> String {
    value.replace(['\t', '\n', '\r'], " ")
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CodexStatusInfo {
    pub(crate) event_name: String,
    pub(crate) matcher: String,
    pub(crate) detail: String,
}

impl CodexStatusInfo {
    pub(crate) fn shell_line(&self) -> String {
        format!(
            "{}\t{}\t{}",
            shell_status_field(&self.event_name),
            shell_status_field(&self.matcher),
            shell_status_field(&self.detail)
        )
    }
}

pub(crate) fn status_info_from_raw(input: &str) -> CodexStatusInfo {
    let data = serde_json::from_str::<Value>(input).ok();
    CodexStatusInfo {
        event_name: data
            .as_ref()
            .map(codex_event_name)
            .unwrap_or("")
            .to_string(),
        matcher: data
            .as_ref()
            .map(codex_status_matcher)
            .unwrap_or("")
            .to_string(),
        detail: data.as_ref().map(codex_status_detail).unwrap_or_default(),
    }
}

fn codex_status_from_output(data: &Value) -> (String, String) {
    let Some(object) = data.as_object() else {
        return ("hook_error".to_string(), "invalid-json".to_string());
    };

    let decision = object
        .get("decision")
        .and_then(Value::as_str)
        .unwrap_or("pass");
    let reason = object
        .get("reason")
        .and_then(Value::as_str)
        .unwrap_or("")
        .replace(['\t', '\n'], " ");

    let mut status = "pass";
    if matches!(
        decision,
        "warn" | "block" | "gate" | "escalate" | "correction"
    ) {
        status = decision;
    } else if decision == "skip" {
        status = "skipped";
    } else if let Some(hook_specific) = object.get("hookSpecificOutput").and_then(Value::as_object)
    {
        if hook_specific
            .get("permissionDecision")
            .and_then(Value::as_str)
            == Some("deny")
        {
            status = "block";
        }
        if hook_specific
            .get("decision")
            .and_then(Value::as_object)
            .and_then(|decision| decision.get("behavior"))
            .and_then(Value::as_str)
            == Some("deny")
        {
            status = "block";
        }
    }

    (status.to_string(), truncate_chars(&reason, 300))
}

pub(crate) fn print_json(value: &Value) -> Result {
    println!("{}", serde_json::to_string_pretty(value)?);
    Ok(())
}

pub(crate) fn deny_pretool_payload(reason: &str) -> Value {
    json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    })
}

pub(crate) fn deny_permission_payload(reason: &str) -> Value {
    json!({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {
                "behavior": "deny",
                "message": reason,
            },
        }
    })
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PatchChange {
    kind: String,
    path: String,
    new_path: Option<String>,
    added_lines: Vec<String>,
    removed_lines: Vec<String>,
}

impl PatchChange {
    fn new(kind: &str, path: &str) -> Self {
        Self {
            kind: kind.to_string(),
            path: path.trim().to_string(),
            new_path: None,
            added_lines: Vec::new(),
            removed_lines: Vec::new(),
        }
    }
}

fn finish_patch_change(changes: &mut Vec<PatchChange>, current: &mut Option<PatchChange>) {
    if let Some(change) = current.take() {
        changes.push(change);
    }
}

fn parse_apply_patch(command: &str) -> Vec<PatchChange> {
    let mut changes = Vec::new();
    let mut current: Option<PatchChange> = None;

    for line in command.lines() {
        if let Some(path) = line.strip_prefix("*** Add File: ") {
            finish_patch_change(&mut changes, &mut current);
            current = Some(PatchChange::new("add", path));
            continue;
        }
        if let Some(path) = line.strip_prefix("*** Update File: ") {
            finish_patch_change(&mut changes, &mut current);
            current = Some(PatchChange::new("update", path));
            continue;
        }
        if let Some(path) = line.strip_prefix("*** Delete File: ") {
            finish_patch_change(&mut changes, &mut current);
            current = Some(PatchChange::new("delete", path));
            continue;
        }

        let Some(change) = current.as_mut() else {
            continue;
        };
        if let Some(path) = line.strip_prefix("*** Move to: ") {
            change.new_path = Some(path.trim().to_string());
        } else if let Some(added) = line.strip_prefix('+') {
            change.added_lines.push(added.to_string());
        } else if let Some(removed) = line.strip_prefix('-') {
            change.removed_lines.push(removed.to_string());
        }
    }

    finish_patch_change(&mut changes, &mut current);
    changes
}

fn apply_patch_command(payload: &Map<String, Value>) -> &str {
    payload
        .get("tool_input")
        .and_then(Value::as_object)
        .and_then(|tool_input| tool_input.get("command"))
        .and_then(Value::as_str)
        .unwrap_or("")
}

fn is_apply_patch_payload(payload: &Map<String, Value>) -> bool {
    if payload.get("tool_name").and_then(Value::as_str) == Some("apply_patch") {
        return true;
    }
    apply_patch_command(payload)
        .trim_start()
        .starts_with("*** Begin Patch")
}

fn normalized_tool_payload(
    payload: &Map<String, Value>,
    tool_name: &str,
    tool_input: Value,
) -> Value {
    let mut normalized = payload.clone();
    normalized.insert("tool_name".to_string(), json!(tool_name));
    normalized.insert("tool_input".to_string(), tool_input);
    Value::Object(normalized)
}

fn normalized_apply_patch_payloads(hook_name: &str, payload: &Map<String, Value>) -> Vec<Value> {
    let event = payload
        .get("hook_event_name")
        .and_then(Value::as_str)
        .unwrap_or("");
    if !matches!(event, "PreToolUse" | "PermissionRequest" | "PostToolUse")
        || !is_apply_patch_payload(payload)
    {
        return vec![Value::Object(payload.clone())];
    }

    let changes = parse_apply_patch(apply_patch_command(payload));
    if changes.is_empty() {
        return vec![Value::Object(payload.clone())];
    }

    if hook_name.contains("pre-write") || hook_name.contains("post-write") {
        return changes
            .into_iter()
            .filter(|change| change.kind == "add")
            .map(|change| {
                normalized_tool_payload(
                    payload,
                    "Write",
                    json!({
                        "file_path": change.path,
                        "content": change.added_lines.join("\n"),
                    }),
                )
            })
            .collect();
    }

    if hook_name.contains("pre-edit") || hook_name.contains("post-edit") {
        return changes
            .into_iter()
            .filter(|change| change.kind != "add")
            .map(|change| {
                let file_path = if change.kind == "update" {
                    change
                        .new_path
                        .clone()
                        .unwrap_or_else(|| change.path.clone())
                } else {
                    change.path.clone()
                };
                let line_delta =
                    change.added_lines.len() as i64 - change.removed_lines.len() as i64;
                normalized_tool_payload(
                    payload,
                    "Edit",
                    json!({
                        "file_path": file_path,
                        "old_string": "",
                        "new_string": change.added_lines.join("\n"),
                        "vibeguard_line_delta": line_delta,
                    }),
                )
            })
            .collect();
    }

    if hook_name.contains("post-build-check") {
        return changes
            .into_iter()
            .map(|change| {
                let file_path = change.new_path.unwrap_or(change.path);
                let tool_name = if change.kind == "add" {
                    "Write"
                } else {
                    "Edit"
                };
                normalized_tool_payload(payload, tool_name, json!({ "file_path": file_path }))
            })
            .collect();
    }

    vec![Value::Object(payload.clone())]
}

pub fn event_name(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-event-name")?;
    let data = read_json_tolerant()?;
    println!("{}", data.as_ref().map(codex_event_name).unwrap_or(""));
    Ok(())
}

pub fn status_detail(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-status-detail")?;
    let data = read_json_tolerant()?;
    println!(
        "{}",
        data.as_ref()
            .map(codex_status_detail)
            .unwrap_or_else(String::new)
    );
    Ok(())
}

pub fn status_matcher(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-status-matcher")?;
    let data = read_json_tolerant()?;
    println!("{}", data.as_ref().map(codex_status_matcher).unwrap_or(""));
    Ok(())
}

pub fn status_info(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-status-info")?;
    let input = read_stdin()?;
    println!("{}", status_info_from_raw(&input).shell_line());
    Ok(())
}

pub fn status_from_output(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-status-from-output")?;
    let input = read_stdin()?;
    let Some(data) = serde_json::from_str::<Value>(&input).ok() else {
        println!("hook_error\tinvalid-json");
        return Ok(());
    };
    let (status, reason) = codex_status_from_output(&data);
    println!("{status}\t{reason}");
    Ok(())
}

pub fn deny_pretool(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-pretool-deny")?;
    let reason = read_stdin()?;
    print_json(&deny_pretool_payload(&reason))
}

pub fn deny_permission(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-permission-deny")?;
    let reason = read_stdin()?;
    print_json(&deny_permission_payload(&reason))
}

pub fn normalize_apply_patch(args: &[String]) -> Result {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime codex-normalize-apply-patch <hook-name>".into());
    }

    let input = read_stdin()?;
    let Ok(Value::Object(payload)) = serde_json::from_str::<Value>(&input) else {
        println!("{input}");
        return Ok(());
    };

    for item in normalized_apply_patch_payloads(&args[0], &payload) {
        println!("{}", serde_json::to_string(&item)?);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn event_name_reads_codex_hook_event() {
        assert_eq!(
            codex_event_name(&json!({"hook_event_name": "PreToolUse"})),
            "PreToolUse"
        );
        assert_eq!(codex_event_name(&json!({"hook_event_name": 7})), "");
    }

    #[test]
    fn logical_session_id_is_stable_across_pre_and_post_payloads() {
        let pre = json!({
            "hook_event_name": "PreToolUse",
            "session_id": "0198c5b1-thread",
            "tool_name": "Edit"
        });
        let post = json!({
            "hook_event_name": "PostToolUse",
            "session_id": "0198c5b1-thread",
            "tool_name": "Edit"
        });
        let id = codex_logical_session_id(&pre);
        assert!(id.starts_with("codex-thread-"));
        assert_eq!(id, codex_logical_session_id(&post));
    }

    #[test]
    fn logical_session_id_separates_threads_and_rejects_missing_or_blank() {
        let a = codex_logical_session_id(&json!({"session_id": "thread-a"}));
        let b = codex_logical_session_id(&json!({"session_id": "thread-b"}));
        assert_ne!(a, b);
        assert_eq!(codex_logical_session_id(&json!({})), "");
        assert_eq!(codex_logical_session_id(&json!({"session_id": "   "})), "");
        assert_eq!(codex_logical_session_id(&json!({"session_id": 7})), "");
    }

    #[test]
    fn status_detail_prefers_file_path_then_command_and_truncates() {
        assert_eq!(
            codex_status_detail(&json!({
                "tool_input": {"file_path": "src/main.rs", "command": "cargo test"}
            })),
            "src/main.rs"
        );
        assert_eq!(
            codex_status_detail(&json!({"tool_input": {"command": "cargo test"}})),
            "cargo test"
        );
        let long = "x".repeat(350);
        assert_eq!(
            codex_status_detail(&json!({"tool_input": {"command": long}}))
                .chars()
                .count(),
            300
        );
    }

    #[test]
    fn status_matcher_reads_tool_name() {
        assert_eq!(codex_status_matcher(&json!({"tool_name": "Bash"})), "Bash");
        assert_eq!(codex_status_matcher(&json!({"tool_name": null})), "");
    }

    #[test]
    fn shell_status_field_removes_line_breaks_and_tabs() {
        assert_eq!(
            shell_status_field("one\ttwo\nthree\rfour"),
            "one two three four"
        );
    }

    #[test]
    fn status_from_output_maps_decisions_and_nested_denies() {
        assert_eq!(
            codex_status_from_output(&json!({"decision": "block", "reason": "no\tway\nnow"})),
            ("block".to_string(), "no way now".to_string())
        );
        assert_eq!(
            codex_status_from_output(&json!({"decision": "skip"})),
            ("skipped".to_string(), String::new())
        );
        assert_eq!(
            codex_status_from_output(&json!({
                "hookSpecificOutput": {"permissionDecision": "deny"}
            })),
            ("block".to_string(), String::new())
        );
        assert_eq!(
            codex_status_from_output(&json!({
                "hookSpecificOutput": {"decision": {"behavior": "deny"}}
            })),
            ("block".to_string(), String::new())
        );
    }

    #[test]
    fn deny_payloads_match_codex_native_shapes() {
        assert_eq!(
            deny_pretool_payload("blocked")["hookSpecificOutput"]["permissionDecision"],
            "deny"
        );
        assert_eq!(
            deny_permission_payload("blocked")["hookSpecificOutput"]["decision"]["behavior"],
            "deny"
        );
    }

    #[test]
    fn parse_apply_patch_collects_change_shapes() {
        let changes = parse_apply_patch(
            "*** Begin Patch\n*** Add File: src/new.rs\n+fn main() {}\n*** Update File: src/old.rs\n*** Move to: src/current.rs\n-old\n+new\n*** Delete File: src/dead.rs\n-old\n*** End Patch",
        );
        assert_eq!(changes.len(), 3);
        assert_eq!(changes[0].kind, "add");
        assert_eq!(changes[0].added_lines, vec!["fn main() {}".to_string()]);
        assert_eq!(changes[1].new_path.as_deref(), Some("src/current.rs"));
        assert_eq!(changes[1].removed_lines, vec!["old".to_string()]);
        assert_eq!(changes[2].kind, "delete");
    }

    #[test]
    fn normalize_apply_patch_fans_out_by_hook_kind() {
        let payload = json!({
            "hook_event_name": "PreToolUse",
            "tool_name": "apply_patch",
            "tool_input": {
                "command": "*** Begin Patch\n*** Add File: src/new.rs\n+one\n+two\n*** Update File: src/existing.rs\n-old\n+new\n*** End Patch"
            },
        })
        .as_object()
        .expect("payload object")
        .clone();

        let write_payloads =
            normalized_apply_patch_payloads("vibeguard-pre-write-guard.sh", &payload);
        assert_eq!(write_payloads.len(), 1);
        assert_eq!(write_payloads[0]["tool_name"], "Write");
        assert_eq!(write_payloads[0]["tool_input"]["file_path"], "src/new.rs");
        assert_eq!(write_payloads[0]["tool_input"]["content"], "one\ntwo");

        let edit_payloads =
            normalized_apply_patch_payloads("vibeguard-pre-edit-guard.sh", &payload);
        assert_eq!(edit_payloads.len(), 1);
        assert_eq!(edit_payloads[0]["tool_name"], "Edit");
        assert_eq!(
            edit_payloads[0]["tool_input"]["file_path"],
            "src/existing.rs"
        );
        assert_eq!(edit_payloads[0]["tool_input"]["new_string"], "new");
        assert_eq!(edit_payloads[0]["tool_input"]["vibeguard_line_delta"], 0);
    }
}
