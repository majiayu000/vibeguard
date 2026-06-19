pub use crate::codex_app_server_hooks::{HookResult, HookRunner};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::Path;

const MAX_APP_SERVER_THREADS: usize = 100;

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
    pub last_seen: u64,
}

#[derive(Debug, Default)]
pub struct SessionState {
    pub threads: HashMap<String, ThreadState>,
    next_seen: u64,
}

impl SessionState {
    pub fn ensure_thread(&mut self, thread_id: &str) -> &mut ThreadState {
        self.next_seen = self.next_seen.saturating_add(1);
        let last_seen = self.next_seen;
        if !self.threads.contains_key(thread_id) && self.threads.len() >= MAX_APP_SERVER_THREADS {
            self.prune_thread_for_insert(thread_id);
        }

        let thread = self
            .threads
            .entry(thread_id.to_string())
            .or_insert_with(|| ThreadState {
                session_id: Some(session_id_for_thread(thread_id)),
                ..ThreadState::default()
            });
        thread.last_seen = last_seen;
        thread
    }

    fn prune_thread_for_insert(&mut self, incoming_thread_id: &str) {
        let victim = self
            .threads
            .iter()
            .filter(|(id, thread)| {
                id.as_str() != incoming_thread_id && thread.pending_file_changes.is_empty()
            })
            .min_by_key(|(_, thread)| thread.last_seen)
            .map(|(id, _)| id.clone())
            .or_else(|| {
                self.threads
                    .iter()
                    .filter(|(id, _)| id.as_str() != incoming_thread_id)
                    .min_by_key(|(_, thread)| thread.last_seen)
                    .map(|(id, _)| id.clone())
            });

        if let Some(victim) = victim {
            self.threads.remove(&victim);
        }
    }
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
        ("VIBEGUARD_CLIENT".into(), "codex".into()),
        ("VIBEGUARD_CLIENT_VARIANT".into(), "codex-app-server".into()),
        (
            "VIBEGUARD_WRAPPER".into(),
            "codex-app-server-wrapper".into(),
        ),
        ("VIBEGUARD_SOURCE_CONFIG".into(), "codex app-server".into()),
        (
            "VIBEGUARD_HOOK_PROTOCOL_VERSION".into(),
            "codex-app-server-jsonrpc-v1".into(),
        ),
        (
            "VIBEGUARD_CALLER_EVIDENCE".into(),
            "codex-app-server-wrapper".into(),
        ),
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
    fn hook_env_records_codex_app_server_caller_identity() {
        let env = hook_env(None, None);

        assert_eq!(env.get("VIBEGUARD_CLI").map(String::as_str), Some("codex"));
        assert_eq!(
            env.get("VIBEGUARD_AGENT_TYPE").map(String::as_str),
            Some("codex")
        );
        assert_eq!(
            env.get("VIBEGUARD_CLIENT").map(String::as_str),
            Some("codex")
        );
        assert_eq!(
            env.get("VIBEGUARD_CLIENT_VARIANT").map(String::as_str),
            Some("codex-app-server")
        );
        assert_eq!(
            env.get("VIBEGUARD_WRAPPER").map(String::as_str),
            Some("codex-app-server-wrapper")
        );
        assert_eq!(
            env.get("VIBEGUARD_HOOK_PROTOCOL_VERSION")
                .map(String::as_str),
            Some("codex-app-server-jsonrpc-v1")
        );
        assert_eq!(
            env.get("VIBEGUARD_CALLER_EVIDENCE").map(String::as_str),
            Some("codex-app-server-wrapper")
        );
    }

    #[test]
    fn ensure_thread_bounds_long_lived_app_server_state() {
        let mut state = SessionState::default();
        for index in 0..(MAX_APP_SERVER_THREADS + 25) {
            state.ensure_thread(&format!("thread-{index}"));
        }

        assert_eq!(state.threads.len(), MAX_APP_SERVER_THREADS);
        assert!(!state.threads.contains_key("thread-0"));
        assert!(
            state
                .threads
                .contains_key(&format!("thread-{}", MAX_APP_SERVER_THREADS + 24))
        );
    }

    #[test]
    fn ensure_thread_prunes_idle_threads_before_pending_file_changes() {
        let mut state = SessionState::default();
        for index in 0..MAX_APP_SERVER_THREADS {
            state.ensure_thread(&format!("thread-{index}"));
        }
        state
            .ensure_thread("thread-0")
            .pending_file_changes
            .insert("turn:item".into(), Vec::new());

        state.ensure_thread("thread-new");

        assert!(state.threads.contains_key("thread-0"));
        assert!(!state.threads.contains_key("thread-1"));
        assert!(state.threads.contains_key("thread-new"));
        assert_eq!(state.threads.len(), MAX_APP_SERVER_THREADS);
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
