use crate::codex_app_server_core::{
    FilePatch, GuardDecisionPolicy, HookResult, HookRunner, SessionState, WriteServer,
    capabilities, emit_feedback_warnings, emit_warning, feedback_messages, file_change_key,
    hook_env, primary_feedback_text, resolve_tool_path, split_unified_diff, unified_diff_hunks,
};
use serde_json::{Value, json};

pub(crate) struct FileChangeApprovalStrategy {
    hooks: HookRunner,
    policy: GuardDecisionPolicy,
}

impl FileChangeApprovalStrategy {
    pub(crate) fn new(hooks: HookRunner, policy: GuardDecisionPolicy) -> Self {
        Self { hooks, policy }
    }

    pub(crate) fn handle(
        &mut self,
        message: &Value,
        state: &mut SessionState,
        write_to_server: &mut WriteServer<'_>,
    ) -> bool {
        match message.get("method").and_then(Value::as_str) {
            Some("applyPatchApproval") => self.handle_apply_patch(message, state, write_to_server),
            Some("item/fileChange/requestApproval") => {
                self.handle_file_change(message, state, write_to_server)
            }
            _ => false,
        }
    }

    pub(crate) fn on_server_notification(
        &mut self,
        message: &Value,
        state: &mut SessionState,
    ) -> Option<Value> {
        match message.get("method").and_then(Value::as_str) {
            Some("item/fileChange/patchUpdated") => self.record_patch_update(message, state),
            Some("item/started") => self.record_started_file_change(message, state),
            Some("item/completed") => return self.complete_file_change(message, state),
            Some("turn/completed") => {
                if let Some(thread_id) = message.get("params").and_then(params_thread_id) {
                    state.ensure_thread(thread_id).pending_file_changes.clear();
                }
            }
            _ => {}
        }
        None
    }

    fn handle_apply_patch(
        &mut self,
        message: &Value,
        state: &mut SessionState,
        write_to_server: &mut WriteServer<'_>,
    ) -> bool {
        let Some(msg_id) = message.get("id").cloned() else {
            return false;
        };
        let Some(params) = message.get("params").and_then(Value::as_object) else {
            return false;
        };
        let thread_id = params
            .get("conversationId")
            .and_then(Value::as_str)
            .map(str::to_string);
        let (cwd, env) = if let Some(thread_id) = &thread_id {
            let thread = state.ensure_thread(thread_id);
            thread.research_streak = 0;
            (thread.cwd.clone(), hook_env(Some(thread_id), Some(thread)))
        } else {
            (None, hook_env(None, None))
        };
        let patches = patches_from_apply_patch_params(&Value::Object(params.clone()));
        if patches.is_empty() {
            return false;
        }
        self.evaluate(
            msg_id,
            self.policy.apply_patch_decline(),
            &patches,
            thread_id.as_deref(),
            cwd.as_deref(),
            &env,
            true,
            write_to_server,
        )
    }

    fn handle_file_change(
        &mut self,
        message: &Value,
        state: &mut SessionState,
        write_to_server: &mut WriteServer<'_>,
    ) -> bool {
        let Some(msg_id) = message.get("id").cloned() else {
            return false;
        };
        let Some(params) = message.get("params").and_then(Value::as_object) else {
            return false;
        };
        let Some(thread_id) = params.get("threadId").and_then(Value::as_str) else {
            return false;
        };

        let thread = state.ensure_thread(thread_id);
        let turn_id = params
            .get("turnId")
            .and_then(Value::as_str)
            .or(thread.turn_id.as_deref());
        let item_id = params.get("itemId").and_then(Value::as_str);
        let key = file_change_key(turn_id, item_id);

        let Some(key) = key else {
            return self.missing_patch_details(msg_id, thread_id, write_to_server);
        };
        let Some(patches) = thread.pending_file_changes.get(&key).cloned() else {
            return self.missing_patch_details(msg_id, thread_id, write_to_server);
        };
        thread.research_streak = 0;
        let cwd = thread.cwd.clone();
        let env = hook_env(Some(thread_id), Some(thread));

        let handled = self.evaluate(
            msg_id,
            self.policy.file_change_decline(),
            &patches,
            Some(thread_id),
            cwd.as_deref(),
            &env,
            false,
            write_to_server,
        );
        if handled {
            state
                .ensure_thread(thread_id)
                .pending_file_changes
                .remove(&key);
        }
        handled
    }

    fn missing_patch_details(
        &self,
        msg_id: Value,
        thread_id: &str,
        write_to_server: &mut WriteServer<'_>,
    ) -> bool {
        let text = "item/fileChange/requestApproval arrived without cached patch details; cannot run file guards";
        if self.policy.blocks_enabled() {
            write_to_server(
                json!({"id": msg_id, "result": {"decision": self.policy.file_change_decline()}}),
            );
            emit_warning(
                write_to_server,
                format!("file-change-guard: {text}"),
                Some(thread_id),
            );
            true
        } else {
            emit_warning(
                write_to_server,
                format!("file-change-guard: {text}; advisory mode left the request untouched"),
                Some(thread_id),
            );
            false
        }
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "approval evaluation requires the complete protocol and hook context"
    )]
    fn evaluate(
        &self,
        msg_id: Value,
        response_decision: &str,
        patches: &[FilePatch],
        thread_id: Option<&str>,
        cwd: Option<&str>,
        env: &std::collections::HashMap<String, String>,
        run_post_hooks: bool,
        write_to_server: &mut WriteServer<'_>,
    ) -> bool {
        let mut pre_block: Option<(String, HookResult)> = None;
        let mut feedback = Vec::new();

        for patch in patches {
            for (hook_name, phase, result) in self.run_file_hooks(patch, cwd, env, run_post_hooks) {
                feedback.extend(feedback_messages(&hook_name, &result));
                if phase == "pre" && self.is_blocking_pre_result(&result) {
                    pre_block = Some((hook_name, result));
                    break;
                }
            }
            if pre_block.is_some() {
                break;
            }
        }

        if let Some((hook_name, result)) = pre_block
            && self.policy.blocks_enabled()
        {
            write_to_server(json!({"id": msg_id, "result": {"decision": response_decision}}));
            let text =
                primary_feedback_text(&hook_name, &result, "file-change guard blocked the edit");
            emit_warning(write_to_server, format!("{hook_name}: {text}"), thread_id);
            eprintln!(
                "[vibeguard-codex-wrapper] blocked file-change approval via {hook_name}: {text}"
            );
            return true;
        }

        emit_feedback_warnings(write_to_server, &feedback, thread_id);
        false
    }

    fn run_file_hooks(
        &self,
        patch: &FilePatch,
        cwd: Option<&str>,
        env: &std::collections::HashMap<String, String>,
        run_post_hooks: bool,
    ) -> Vec<(String, &'static str, HookResult)> {
        let path = resolve_tool_path(&patch.path, cwd);
        let mut results = Vec::new();
        match patch.normalized_kind() {
            "add" => {
                let content = patch
                    .content
                    .clone()
                    .unwrap_or_else(|| split_unified_diff(&patch.diff).1);
                let payload = json!({"tool_input": {"file_path": path, "content": content}});
                let pre = self.hooks.run("pre-write-guard.sh", &payload, cwd, env);
                let blocked = self.is_blocking_pre_result(&pre);
                results.push(("pre-write-guard.sh".into(), "pre", pre));
                if !blocked && run_post_hooks {
                    results.push((
                        "post-write-guard.sh".into(),
                        "post",
                        self.hooks.run("post-write-guard.sh", &payload, cwd, env),
                    ));
                }
            }
            "update" => {
                for hunk in unified_diff_hunks(&patch.diff) {
                    let pre_payload = json!({
                        "tool_input": {
                            "file_path": path,
                            "old_string": hunk.old_string,
                            "new_string": hunk.new_string,
                        }
                    });
                    let pre = self.hooks.run("pre-edit-guard.sh", &pre_payload, cwd, env);
                    let blocked = self.is_blocking_pre_result(&pre);
                    results.push(("pre-edit-guard.sh".into(), "pre", pre));
                    if blocked {
                        break;
                    }
                    if run_post_hooks {
                        let post_payload = json!({
                            "tool_input": {
                                "file_path": path,
                                "old_string": hunk.old_string,
                                "new_string": if hunk.added_string.is_empty() { hunk.new_string } else { hunk.added_string },
                            }
                        });
                        results.push((
                            "post-edit-guard.sh".into(),
                            "post",
                            self.hooks
                                .run("post-edit-guard.sh", &post_payload, cwd, env),
                        ));
                    }
                }
            }
            "delete" => {
                let old_string = patch
                    .content
                    .clone()
                    .unwrap_or_else(|| split_unified_diff(&patch.diff).0);
                let payload = json!({
                    "tool_input": {
                        "file_path": path,
                        "old_string": old_string,
                        "new_string": "",
                    }
                });
                results.push((
                    "pre-edit-guard.sh".into(),
                    "pre",
                    self.hooks.run("pre-edit-guard.sh", &payload, cwd, env),
                ));
            }
            other => results.push((
                "file-change-guard".into(),
                "pre",
                HookResult::hook_error(format!("unsupported file change kind: {other}")),
            )),
        }
        results
    }

    fn run_file_post_hooks(
        &self,
        patch: &FilePatch,
        cwd: Option<&str>,
        env: &std::collections::HashMap<String, String>,
    ) -> Vec<(String, HookResult)> {
        let path = resolve_tool_path(&patch.path, cwd);
        match patch.normalized_kind() {
            "add" => {
                let content = patch
                    .content
                    .clone()
                    .unwrap_or_else(|| split_unified_diff(&patch.diff).1);
                let payload = json!({"tool_input": {"file_path": path, "content": content}});
                vec![(
                    "post-write-guard.sh".into(),
                    self.hooks.run("post-write-guard.sh", &payload, cwd, env),
                )]
            }
            "update" => unified_diff_hunks(&patch.diff)
                .into_iter()
                .map(|hunk| {
                    let payload = json!({
                        "tool_input": {
                            "file_path": path.clone(),
                            "old_string": hunk.old_string,
                            "new_string": if hunk.added_string.is_empty() { hunk.new_string } else { hunk.added_string },
                        }
                    });
                    (
                        "post-edit-guard.sh".into(),
                        self.hooks.run("post-edit-guard.sh", &payload, cwd, env),
                    )
                })
                .collect(),
            "delete" => Vec::new(),
            _ => Vec::new(),
        }
    }

    fn is_blocking_pre_result(&self, result: &HookResult) -> bool {
        if !matches!(
            result.decision.as_str(),
            "pass" | "allow" | "warn" | "block" | "hook_error" | "skip"
        ) {
            return true;
        }
        self.policy.should_block_pre_hook(result)
    }

    fn complete_file_change(&mut self, message: &Value, state: &mut SessionState) -> Option<Value> {
        let params = message.get("params")?;
        if params
            .get("item")
            .and_then(|item| item.get("type"))
            .and_then(Value::as_str)
            != Some("fileChange")
        {
            return None;
        }
        let thread_id = params_thread_id(params)?;
        let turn_id = params_turn_id(params);
        let item_id = params_item_id(params)?;
        let key = file_change_key(turn_id, Some(item_id))?;
        let completed = params_item_status(params) == Some("completed");

        let (patches, cwd, env, session_id) = {
            let thread = state.ensure_thread(thread_id);
            if let Some(turn_id) = turn_id.filter(|s| !s.is_empty()) {
                thread.turn_id = Some(turn_id.into());
            }
            let patches = thread.pending_file_changes.remove(&key);
            let cwd = thread.cwd.clone();
            let env = hook_env(Some(thread_id), Some(thread));
            (patches, cwd, env, thread.session_id.clone())
        };

        if !completed {
            return None;
        }
        let patches = patches?;
        let mut messages = Vec::new();
        for patch in &patches {
            for (hook_name, result) in self.run_file_post_hooks(patch, cwd.as_deref(), &env) {
                messages.extend(feedback_messages(&hook_name, &result));
            }
        }
        if messages.is_empty() {
            return None;
        }
        Some(json!({
            "client": "codex-app-server",
            "capabilities": capabilities(),
            "messages": messages,
            "sessionId": session_id,
            "threadId": thread_id,
            "turnId": turn_id,
            "itemId": item_id,
        }))
    }

    fn record_patch_update(&mut self, message: &Value, state: &mut SessionState) {
        let Some(params) = message.get("params") else {
            return;
        };
        let Some(thread_id) = params.get("threadId").and_then(Value::as_str) else {
            return;
        };
        let Some(turn_id) = params.get("turnId").and_then(Value::as_str) else {
            return;
        };
        let Some(item_id) = params.get("itemId").and_then(Value::as_str) else {
            return;
        };
        let Some(changes) = params.get("changes").and_then(Value::as_array) else {
            return;
        };
        self.record_file_changes(state, thread_id, turn_id, item_id, changes);
    }

    fn record_started_file_change(&mut self, message: &Value, state: &mut SessionState) {
        let Some(params) = message.get("params") else {
            return;
        };
        let Some(thread_id) = params.get("threadId").and_then(Value::as_str) else {
            return;
        };
        let Some(turn_id) = params.get("turnId").and_then(Value::as_str) else {
            return;
        };
        let Some(item) = params.get("item") else {
            return;
        };
        if item.get("type").and_then(Value::as_str) != Some("fileChange") {
            return;
        }
        let Some(item_id) = item.get("id").and_then(Value::as_str) else {
            return;
        };
        let Some(changes) = item.get("changes").and_then(Value::as_array) else {
            return;
        };
        self.record_file_changes(state, thread_id, turn_id, item_id, changes);
    }

    fn record_file_changes(
        &mut self,
        state: &mut SessionState,
        thread_id: &str,
        turn_id: &str,
        item_id: &str,
        changes: &[Value],
    ) {
        let patches = patches_from_change_values(changes);
        let thread = state.ensure_thread(thread_id);
        thread.turn_id = Some(turn_id.into());
        if let Some(key) = file_change_key(Some(turn_id), Some(item_id)) {
            thread.pending_file_changes.insert(key, patches);
        }
    }
}

fn patches_from_change_values(changes: &[Value]) -> Vec<FilePatch> {
    changes
        .iter()
        .filter_map(|change| {
            Some(FilePatch {
                path: change.get("path")?.as_str()?.into(),
                kind: change.get("kind")?.as_str()?.into(),
                diff: change
                    .get("diff")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .into(),
                content: change
                    .get("content")
                    .and_then(Value::as_str)
                    .map(str::to_string),
            })
        })
        .collect::<Vec<_>>()
}

fn patches_from_apply_patch_params(params: &Value) -> Vec<FilePatch> {
    let Some(file_changes) = params.get("fileChanges").and_then(Value::as_object) else {
        return Vec::new();
    };
    file_changes
        .iter()
        .filter_map(|(path, change)| {
            Some(FilePatch {
                path: path.clone(),
                kind: change.get("type")?.as_str()?.into(),
                diff: change
                    .get("unified_diff")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .into(),
                content: change
                    .get("content")
                    .and_then(Value::as_str)
                    .map(str::to_string),
            })
        })
        .collect()
}

pub(crate) fn params_thread_id(params: &Value) -> Option<&str> {
    params
        .get("threadId")
        .and_then(Value::as_str)
        .or_else(|| {
            params
                .get("turn")
                .and_then(|turn| turn.get("threadId"))
                .and_then(Value::as_str)
        })
        .or_else(|| {
            params
                .get("item")
                .and_then(|item| item.get("threadId"))
                .and_then(Value::as_str)
        })
}

pub(crate) fn params_turn_id(params: &Value) -> Option<&str> {
    params
        .get("turnId")
        .and_then(Value::as_str)
        .or_else(|| {
            params
                .get("turn")
                .and_then(|turn| turn.get("turnId"))
                .and_then(Value::as_str)
        })
        .or_else(|| {
            params
                .get("turn")
                .and_then(|turn| turn.get("id"))
                .and_then(Value::as_str)
        })
        .or_else(|| {
            params
                .get("item")
                .and_then(|item| item.get("turnId"))
                .and_then(Value::as_str)
        })
}

fn params_item_id(params: &Value) -> Option<&str> {
    params.get("itemId").and_then(Value::as_str).or_else(|| {
        params
            .get("item")
            .and_then(|item| item.get("id"))
            .and_then(Value::as_str)
    })
}

fn params_item_status(params: &Value) -> Option<&str> {
    params.get("status").and_then(Value::as_str).or_else(|| {
        params
            .get("item")
            .and_then(|item| item.get("status"))
            .and_then(Value::as_str)
    })
}

pub(crate) fn attach_vibeguard_feedback(mut message: Value, feedback: Value) -> Value {
    if let Some(params) = message.get_mut("params").and_then(Value::as_object_mut) {
        params.insert("vibeguard".into(), feedback);
    }
    message
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protocol_helpers_support_nested_turn_and_item_shapes() {
        let params = json!({
            "turn": {
                "id": "turn-1",
                "threadId": "thread-1"
            },
            "item": {
                "id": "item-1",
                "type": "fileChange",
                "status": "completed"
            }
        });

        assert_eq!(params_thread_id(&params), Some("thread-1"));
        assert_eq!(params_turn_id(&params), Some("turn-1"));
        assert_eq!(params_item_id(&params), Some("item-1"));
        assert_eq!(params_item_status(&params), Some("completed"));
    }

    #[test]
    fn change_payloads_preserve_file_patch_fields() {
        let changes = vec![json!({
            "path": "src/lib.rs",
            "kind": "update",
            "diff": "--- a/src/lib.rs\n+++ b/src/lib.rs\n@@\n-old\n+new\n",
            "content": "new"
        })];

        let patches = patches_from_change_values(&changes);

        assert_eq!(patches.len(), 1);
        assert_eq!(patches[0].path, "src/lib.rs");
        assert_eq!(patches[0].normalized_kind(), "update");
        assert_eq!(patches[0].content.as_deref(), Some("new"));
    }
}
