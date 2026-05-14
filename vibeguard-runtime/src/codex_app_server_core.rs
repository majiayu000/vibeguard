use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub type WriteServer<'a> = dyn FnMut(Value) + 'a;

pub fn capabilities() -> Value {
    json!({
        "pre_bash_guard": true,
        "command_rewrite": true,
        "post_turn_feedback": true,
        "file_change_guard": true,
        "pre_edit_guard": true,
        "pre_write_guard": true,
        "post_edit_guard": true,
        "post_write_guard": true,
        "analysis_paralysis_guard": true,
    })
}

#[derive(Debug, Default)]
pub struct ThreadState {
    pub cwd: Option<String>,
    pub session_id: Option<String>,
    pub turn_id: Option<String>,
    pub pending_file_changes: HashMap<String, Vec<FilePatch>>,
    pub research_streak: usize,
}

#[derive(Debug, Default)]
pub struct SessionState {
    pub threads: HashMap<String, ThreadState>,
}

impl SessionState {
    pub fn ensure_thread(&mut self, thread_id: &str) -> &mut ThreadState {
        self.threads
            .entry(thread_id.to_string())
            .or_insert_with(|| ThreadState {
                session_id: Some(session_id_for_thread(thread_id)),
                ..ThreadState::default()
            })
    }
}

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
        if !hook_path.exists() {
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
        if let Some(mut stdin) = child.stdin.take() {
            if let Err(e) = stdin.write_all(payload.to_string().as_bytes()) {
                return HookResult::hook_error(e.to_string());
            }
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

        HookResult {
            decision,
            output: stripped,
            payloads,
            reason,
            updated_command,
            failed: false,
        }
    }
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
        if let Ok(value) = serde_json::from_str::<Value>(&candidate) {
            if value.is_object() {
                payloads.push(value);
            }
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

#[derive(Debug, Clone)]
pub struct FilePatch {
    pub path: String,
    pub kind: String,
    pub diff: String,
    pub content: Option<String>,
}

impl FilePatch {
    pub fn normalized_kind(&self) -> &str {
        match self.kind.as_str() {
            "add" | "create" | "write" => "add",
            "update" | "modify" | "edit" => "update",
            "delete" | "remove" => "delete",
            other => other,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffHunk {
    pub old_string: String,
    pub new_string: String,
    pub added_string: String,
}

pub struct GuardDecisionPolicy {
    mode: String,
}

impl GuardDecisionPolicy {
    pub fn new(mode: Option<&str>) -> Self {
        let selected = mode
            .map(str::to_string)
            .or_else(|| std::env::var("VIBEGUARD_CODEX_GUARD_MODE").ok())
            .unwrap_or_else(|| "guarded".into())
            .to_ascii_lowercase();
        let mode = match selected.as_str() {
            "advisory" | "guarded" | "strict" => selected,
            _ => "guarded".into(),
        };
        Self { mode }
    }

    pub fn blocks_enabled(&self) -> bool {
        self.mode != "advisory"
    }

    pub fn file_change_decline(&self) -> &'static str {
        if self.mode == "strict" {
            "cancel"
        } else {
            "decline"
        }
    }

    pub fn apply_patch_decline(&self) -> &'static str {
        if self.mode == "strict" {
            "abort"
        } else {
            "denied"
        }
    }

    pub fn should_block_pre_hook(&self, result: &HookResult) -> bool {
        self.blocks_enabled()
            && (result.failed || matches!(result.decision.as_str(), "block" | "hook_error"))
    }
}

pub trait GateStrategy: Send {
    fn on_client_message(&mut self, message: &Value, state: &mut SessionState);
    fn handle_server_request(
        &mut self,
        message: &Value,
        state: &mut SessionState,
        write_to_server: &mut WriteServer<'_>,
    ) -> bool;
    fn on_server_notification(&mut self, message: Value, state: &mut SessionState) -> Value;
}

pub struct NoopGateStrategy;

impl GateStrategy for NoopGateStrategy {
    fn on_client_message(&mut self, _message: &Value, _state: &mut SessionState) {}

    fn handle_server_request(
        &mut self,
        _message: &Value,
        _state: &mut SessionState,
        _write_to_server: &mut WriteServer<'_>,
    ) -> bool {
        false
    }

    fn on_server_notification(&mut self, message: Value, _state: &mut SessionState) -> Value {
        message
    }
}

pub fn hook_env(thread_id: Option<&str>, thread: Option<&ThreadState>) -> HashMap<String, String> {
    let mut env = HashMap::from([
        ("VIBEGUARD_CLI".into(), "codex".into()),
        ("VIBEGUARD_AGENT_TYPE".into(), "codex".into()),
    ]);
    if let Some(thread) = thread {
        if let Some(session_id) = &thread.session_id {
            env.insert("VIBEGUARD_SESSION_ID".into(), session_id.clone());
        }
        if let Some(turn_id) = &thread.turn_id {
            env.insert("VIBEGUARD_TURN_ID".into(), turn_id.clone());
        }
    }
    if let Some(thread_id) = thread_id {
        env.insert("VIBEGUARD_THREAD_ID".into(), thread_id.into());
    }
    env
}

pub fn feedback_messages(hook_name: &str, result: &HookResult) -> Vec<Value> {
    let mut messages = Vec::new();
    if let Some(reason) = &result.reason {
        messages.push(json!({"hook": hook_name, "kind": "reason", "text": reason}));
    }
    if result.decision == "hook_error" || result.failed {
        messages.push(json!({"hook": hook_name, "kind": "hookError", "text": result.output}));
    }
    for payload in &result.payloads {
        for (field, kind) in [
            ("stopReason", "stopReason"),
            ("systemMessage", "systemMessage"),
        ] {
            if let Some(text) = string_field(payload, field) {
                if !text.is_empty() {
                    messages.push(json!({"hook": hook_name, "kind": kind, "text": text}));
                }
            }
        }
        if let Some(text) = payload
            .get("hookSpecificOutput")
            .and_then(|v| v.get("additionalContext"))
            .and_then(Value::as_str)
        {
            if !text.is_empty() {
                messages
                    .push(json!({"hook": hook_name, "kind": "additionalContext", "text": text}));
            }
        }
    }
    messages
}

pub fn primary_feedback_text(hook_name: &str, result: &HookResult, fallback: &str) -> String {
    feedback_messages(hook_name, result)
        .iter()
        .find_map(|m| m.get("text").and_then(Value::as_str).map(str::to_string))
        .unwrap_or_else(|| {
            if result.output.is_empty() {
                fallback.into()
            } else {
                result.output.clone()
            }
        })
}

pub fn emit_warning(
    write_to_server: &mut WriteServer<'_>,
    text: impl Into<String>,
    thread_id: Option<&str>,
) {
    let text = text.into();
    if text.is_empty() {
        return;
    }
    let mut params = serde_json::Map::from_iter([("message".into(), json!(text))]);
    if let Some(thread_id) = thread_id {
        params.insert("threadId".into(), json!(thread_id));
    }
    write_to_server(json!({"method": "warning", "params": Value::Object(params)}));
}

pub fn emit_feedback_warnings(
    write_to_server: &mut WriteServer<'_>,
    messages: &[Value],
    thread_id: Option<&str>,
) {
    let mut lines = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for message in messages {
        let hook = message
            .get("hook")
            .and_then(Value::as_str)
            .unwrap_or("vibeguard");
        let text = message.get("text").and_then(Value::as_str).unwrap_or("");
        if text.is_empty() {
            continue;
        }
        let key = format!("{hook}\0{text}");
        if seen.insert(key) {
            lines.push(format!("{hook}: {text}"));
        }
    }
    emit_warning(write_to_server, lines.join("\n"), thread_id);
}

pub fn resolve_tool_path(path: &str, cwd: Option<&str>) -> String {
    let p = Path::new(path);
    if p.is_absolute() {
        path.into()
    } else if let Some(cwd) = cwd {
        Path::new(cwd).join(path).to_string_lossy().to_string()
    } else {
        path.into()
    }
}

pub fn split_unified_diff(diff: &str) -> (String, String) {
    let mut old_lines = Vec::new();
    let mut new_lines = Vec::new();
    for line in diff.lines() {
        if line.starts_with("---") || line.starts_with("+++") || line.starts_with("@@") {
            continue;
        }
        if let Some(rest) = line.strip_prefix('-') {
            old_lines.push(rest);
        } else if let Some(rest) = line.strip_prefix('+') {
            new_lines.push(rest);
        }
    }
    (old_lines.join("\n"), new_lines.join("\n"))
}

pub fn unified_diff_hunks(diff: &str) -> Vec<DiffHunk> {
    let mut hunks = Vec::new();
    let mut old_lines = Vec::new();
    let mut new_lines = Vec::new();
    let mut added_lines = Vec::new();
    let mut seen_change = false;

    let flush = |hunks: &mut Vec<DiffHunk>,
                 old_lines: &mut Vec<String>,
                 new_lines: &mut Vec<String>,
                 added_lines: &mut Vec<String>,
                 seen_change: &mut bool| {
        if *seen_change {
            hunks.push(DiffHunk {
                old_string: old_lines.join("\n"),
                new_string: new_lines.join("\n"),
                added_string: added_lines.join("\n"),
            });
        }
        old_lines.clear();
        new_lines.clear();
        added_lines.clear();
        *seen_change = false;
    };

    for line in diff.lines() {
        if line.starts_with("---") || line.starts_with("+++") {
            continue;
        }
        if line.starts_with("@@") {
            flush(
                &mut hunks,
                &mut old_lines,
                &mut new_lines,
                &mut added_lines,
                &mut seen_change,
            );
            continue;
        }
        if let Some(rest) = line.strip_prefix('-') {
            old_lines.push(rest.into());
            seen_change = true;
        } else if let Some(rest) = line.strip_prefix('+') {
            new_lines.push(rest.into());
            added_lines.push(rest.into());
            seen_change = true;
        } else if let Some(rest) = line.strip_prefix(' ') {
            old_lines.push(rest.into());
            new_lines.push(rest.into());
        }
    }
    flush(
        &mut hunks,
        &mut old_lines,
        &mut new_lines,
        &mut added_lines,
        &mut seen_change,
    );
    hunks
}

pub fn file_change_key(turn_id: Option<&str>, item_id: Option<&str>) -> Option<String> {
    Some(format!("{}:{}", turn_id?, item_id?))
}

pub fn string_field(value: &Value, field: &str) -> Option<String> {
    value.get(field).and_then(Value::as_str).map(str::to_string)
}

pub fn session_id_for_thread(thread_id: &str) -> String {
    let normalized = thread_id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-') {
                c
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .to_string();
    let normalized = if normalized.is_empty() {
        "thread".into()
    } else {
        normalized
    };
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in thread_id.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!(
        "codex-thread-{normalized}-{:012x}",
        hash & 0x0000_ffff_ffff_ffff
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capabilities_advertise_codex_guard_surfaces() {
        let value = capabilities();

        assert_eq!(value["pre_bash_guard"], true);
        assert_eq!(value["file_change_guard"], true);
        assert_eq!(value["post_turn_feedback"], true);
        assert_eq!(value["analysis_paralysis_guard"], true);
    }

    #[test]
    fn extract_payloads_deduplicates_full_and_line_json() {
        let output = "{\"decision\":\"pass\"}\n{\"decision\":\"pass\"}\nnot-json\n";
        let payloads = extract_payloads(output);

        assert_eq!(payloads, vec![json!({"decision": "pass"})]);
    }

    #[test]
    fn file_patch_normalized_kind_maps_known_aliases() {
        let add = FilePatch {
            path: "src/lib.rs".into(),
            kind: "create".into(),
            diff: String::new(),
            content: None,
        };
        let update = FilePatch {
            kind: "edit".into(),
            ..add.clone()
        };
        let delete = FilePatch {
            kind: "remove".into(),
            ..add.clone()
        };

        assert_eq!(add.normalized_kind(), "add");
        assert_eq!(update.normalized_kind(), "update");
        assert_eq!(delete.normalized_kind(), "delete");
    }

    #[test]
    fn guard_policy_modes_control_blocking() {
        let advisory = GuardDecisionPolicy::new(Some("advisory"));
        let guarded = GuardDecisionPolicy::new(Some("guarded"));
        let strict = GuardDecisionPolicy::new(Some("strict"));
        let blocked = HookResult {
            decision: "block".into(),
            output: String::new(),
            payloads: Vec::new(),
            reason: None,
            updated_command: None,
            failed: false,
        };

        assert!(!advisory.blocks_enabled());
        assert!(!advisory.should_block_pre_hook(&blocked));
        assert!(guarded.should_block_pre_hook(&blocked));
        assert_eq!(guarded.file_change_decline(), "decline");
        assert_eq!(strict.file_change_decline(), "cancel");
        assert_eq!(strict.apply_patch_decline(), "abort");
    }
}
