use crate::codex_app_server_core::{
    FilePatch, GateStrategy, GuardDecisionPolicy, HookResult, HookRunner, SessionState,
    ThreadState, WriteServer, capabilities, emit_feedback_warnings, emit_warning,
    feedback_messages, file_change_key, hook_env, primary_feedback_text, resolve_tool_path,
    split_unified_diff, unified_diff_hunks,
};
use regex::Regex;
use serde_json::{Value, json};
use std::path::Path;
use std::process::Command;

struct AnalysisParalysisStrategy {
    read_re: Regex,
    write_re: Regex,
    threshold: usize,
}

impl AnalysisParalysisStrategy {
    fn new() -> Result<Self, regex::Error> {
        let threshold = std::env::var("VG_PARALYSIS_THRESHOLD")
            .ok()
            .and_then(|v| v.parse::<usize>().ok())
            .unwrap_or(7)
            .max(1);
        Ok(Self {
            read_re: Regex::new(
                r"(^|\b)(rg|grep|fd|find|ls|cat|sed|awk|head|tail|wc|tree|nl)\b|\bgit\s+(show|diff|log|status|grep|ls-files)\b",
            )?,
            write_re: Regex::new(
                r"\b(apply_patch|git\s+(add|commit|mv|rm)|mkdir|touch|mv|cp|rm|tee|install)\b|>\s*[^&]|>>\s*[^&]|\bsed\s+-i\b",
            )?,
            threshold,
        })
    }

    fn observe_command(
        &self,
        command: &str,
        thread_id: Option<&str>,
        thread: Option<&mut ThreadState>,
        write_to_server: &mut WriteServer<'_>,
    ) {
        let Some(thread) = thread else {
            return;
        };
        if self.write_re.is_match(command) {
            thread.research_streak = 0;
            return;
        }
        if !self.read_re.is_match(command) {
            return;
        }
        thread.research_streak += 1;
        if thread.research_streak >= self.threshold {
            emit_warning(
                write_to_server,
                format!(
                    "analysis-paralysis-guard: VIBEGUARD analysis paralysis warning: {} consecutive read-only commands without a file change. Start editing, or report the blocker and the exact missing evidence.",
                    thread.research_streak
                ),
                thread_id,
            );
        }
    }
}

struct CommandApprovalStrategy {
    hooks: HookRunner,
    policy: GuardDecisionPolicy,
    analysis: AnalysisParalysisStrategy,
}

impl CommandApprovalStrategy {
    fn handle(
        &mut self,
        message: &Value,
        state: &mut SessionState,
        write_to_server: &mut WriteServer<'_>,
    ) -> bool {
        if message.get("method").and_then(Value::as_str)
            != Some("item/commandExecution/requestApproval")
        {
            return false;
        }
        let Some(msg_id) = message.get("id").cloned() else {
            return false;
        };
        let Some(params) = message.get("params").and_then(Value::as_object) else {
            return false;
        };
        let Some(command) = params
            .get("command")
            .and_then(Value::as_str)
            .filter(|s| !s.trim().is_empty())
        else {
            return false;
        };
        let thread_id = params
            .get("threadId")
            .and_then(Value::as_str)
            .map(str::to_string);

        let (cwd, env) = if let Some(thread_id) = &thread_id {
            let thread = state.ensure_thread(thread_id);
            (thread.cwd.clone(), hook_env(Some(thread_id), Some(thread)))
        } else {
            (None, hook_env(None, None))
        };

        let result = self.hooks.run(
            "pre-bash-guard.sh",
            &json!({"tool_input": {"command": command}}),
            cwd.as_deref(),
            &env,
        );

        if self.policy.should_block_pre_hook(&result) {
            write_to_server(json!({"id": msg_id, "result": {"decision": "decline"}}));
            let text = primary_feedback_text(
                "pre-bash-guard.sh",
                &result,
                "pre-bash hook blocked the command",
            );
            emit_warning(
                write_to_server,
                format!("pre-bash-guard.sh: {text}"),
                thread_id.as_deref(),
            );
            if result.decision == "hook_error" || result.failed {
                eprintln!(
                    "[vibeguard-codex-wrapper] pre-bash hook failed; declining command approval: {command}\n{}",
                    result.output
                );
            } else {
                eprintln!("[vibeguard-codex-wrapper] blocked command approval: {command}");
            }
            return true;
        }

        if result.decision == "warn" {
            let text = primary_feedback_text("pre-bash-guard.sh", &result, "");
            emit_warning(write_to_server, text, thread_id.as_deref());
            self.observe(command, thread_id.as_deref(), state, write_to_server);
            return false;
        }

        if !matches!(
            result.decision.as_str(),
            "pass" | "allow" | "block" | "hook_error"
        ) {
            if self.policy.blocks_enabled() {
                write_to_server(json!({"id": msg_id, "result": {"decision": "decline"}}));
                let text = format!(
                    "unexpected pre-bash-guard decision {:?}; declining command approval",
                    result.decision
                );
                emit_warning(
                    write_to_server,
                    format!("pre-bash-guard.sh: {text}"),
                    thread_id.as_deref(),
                );
                eprintln!("[vibeguard-codex-wrapper] {text}: {command}");
                return true;
            }
            emit_warning(
                write_to_server,
                format!(
                    "pre-bash-guard.sh: unexpected decision {:?}; advisory mode left the request untouched",
                    result.decision
                ),
                thread_id.as_deref(),
            );
        }

        if let Some(updated_command) = result.updated_command {
            write_to_server(json!({
                "id": msg_id,
                "result": {"decision": "approve", "updatedInput": {"command": updated_command}}
            }));
            eprintln!(
                "[vibeguard-codex-wrapper] corrected command: {command:?} -> {updated_command:?}"
            );
            self.observe(
                &updated_command,
                thread_id.as_deref(),
                state,
                write_to_server,
            );
            return true;
        }

        if matches!(result.decision.as_str(), "block" | "hook_error") {
            let text = primary_feedback_text(
                "pre-bash-guard.sh",
                &result,
                "pre-bash hook would block in guarded mode",
            );
            emit_warning(
                write_to_server,
                format!("pre-bash-guard.sh: {text}"),
                thread_id.as_deref(),
            );
        }

        self.observe(command, thread_id.as_deref(), state, write_to_server);
        false
    }

    fn observe(
        &self,
        command: &str,
        thread_id: Option<&str>,
        state: &mut SessionState,
        write_to_server: &mut WriteServer<'_>,
    ) {
        let thread = thread_id.map(|id| state.ensure_thread(id));
        self.analysis
            .observe_command(command, thread_id, thread, write_to_server);
    }
}

struct FileChangeApprovalStrategy {
    hooks: HookRunner,
    policy: GuardDecisionPolicy,
}

impl FileChangeApprovalStrategy {
    fn handle(
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

    fn on_server_notification(&mut self, message: &Value, state: &mut SessionState) {
        match message.get("method").and_then(Value::as_str) {
            Some("item/fileChange/patchUpdated") => self.record_patch_update(message, state),
            Some("turn/completed") => {
                if let Some(thread_id) = message
                    .get("params")
                    .and_then(|p| p.get("threadId"))
                    .and_then(Value::as_str)
                {
                    state.ensure_thread(thread_id).pending_file_changes.clear();
                }
            }
            _ => {}
        }
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

        self.evaluate(
            msg_id,
            self.policy.file_change_decline(),
            &patches,
            Some(thread_id),
            cwd.as_deref(),
            &env,
            write_to_server,
        )
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

    fn evaluate(
        &self,
        msg_id: Value,
        response_decision: &str,
        patches: &[FilePatch],
        thread_id: Option<&str>,
        cwd: Option<&str>,
        env: &std::collections::HashMap<String, String>,
        write_to_server: &mut WriteServer<'_>,
    ) -> bool {
        let mut pre_block: Option<(String, HookResult)> = None;
        let mut feedback = Vec::new();

        for patch in patches {
            for (hook_name, phase, result) in self.run_file_hooks(patch, cwd, env) {
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

        if let Some((hook_name, result)) = pre_block {
            if self.policy.blocks_enabled() {
                write_to_server(json!({"id": msg_id, "result": {"decision": response_decision}}));
                let text = primary_feedback_text(
                    &hook_name,
                    &result,
                    "file-change guard blocked the edit",
                );
                emit_warning(write_to_server, format!("{hook_name}: {text}"), thread_id);
                eprintln!(
                    "[vibeguard-codex-wrapper] blocked file-change approval via {hook_name}: {text}"
                );
                return true;
            }
        }

        emit_feedback_warnings(write_to_server, &feedback, thread_id);
        false
    }

    fn run_file_hooks(
        &self,
        patch: &FilePatch,
        cwd: Option<&str>,
        env: &std::collections::HashMap<String, String>,
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
                if !blocked {
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
                    let post_payload = json!({
                        "tool_input": {
                            "file_path": path,
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
            "delete" => {}
            other => results.push((
                "file-change-guard".into(),
                "pre",
                HookResult::hook_error(format!("unsupported file change kind: {other}")),
            )),
        }
        results
    }

    fn is_blocking_pre_result(&self, result: &HookResult) -> bool {
        if !matches!(
            result.decision.as_str(),
            "pass" | "allow" | "warn" | "block" | "hook_error"
        ) {
            return true;
        }
        self.policy.should_block_pre_hook(result)
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
        let patches = changes
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
                    content: None,
                })
            })
            .collect::<Vec<_>>();
        let thread = state.ensure_thread(thread_id);
        thread.turn_id = Some(turn_id.into());
        if let Some(key) = file_change_key(Some(turn_id), Some(item_id)) {
            thread.pending_file_changes.insert(key, patches);
        }
    }
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

struct PostTurnFeedbackStrategy {
    hooks: HookRunner,
}

impl PostTurnFeedbackStrategy {
    fn collect(&self, cwd: &str, thread_id: &str, thread: &ThreadState) -> Option<Value> {
        let env = hook_env(Some(thread_id), Some(thread));
        let mut messages = Vec::new();
        for hook_name in ["stop-guard.sh", "learn-evaluator.sh"] {
            let result = self.hooks.run(hook_name, &json!({}), Some(cwd), &env);
            messages.extend(feedback_messages(hook_name, &result));
        }
        for rel in changed_files(cwd) {
            let payload =
                json!({"tool_input": {"file_path": Path::new(cwd).join(rel).to_string_lossy()}});
            let result = self
                .hooks
                .run("post-build-check.sh", &payload, Some(cwd), &env);
            messages.extend(feedback_messages("post-build-check.sh", &result));
        }
        if messages.is_empty() {
            return None;
        }
        Some(json!({
            "client": "codex-app-server",
            "capabilities": capabilities(),
            "messages": messages,
            "sessionId": thread.session_id,
            "threadId": thread_id,
            "turnId": thread.turn_id,
        }))
    }
}

fn changed_files(cwd: &str) -> Vec<String> {
    let mut changed = std::collections::BTreeSet::new();
    for args in [
        ["diff", "--name-only", "HEAD"].as_slice(),
        ["diff", "--name-only", "--cached"].as_slice(),
        ["ls-files", "--others", "--exclude-standard"].as_slice(),
    ] {
        let Ok(output) = Command::new("git").arg("-C").arg(cwd).args(args).output() else {
            continue;
        };
        if !output.status.success() {
            continue;
        }
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            let line = line.trim();
            if matches!(
                Path::new(line).extension().and_then(|s| s.to_str()),
                Some("rs" | "py" | "ts" | "tsx" | "js" | "jsx" | "go")
            ) {
                changed.insert(line.to_string());
            }
        }
    }
    changed.into_iter().collect()
}

pub struct VibeGuardGateStrategy {
    command_strategy: CommandApprovalStrategy,
    file_change_strategy: FileChangeApprovalStrategy,
    post_turn_strategy: PostTurnFeedbackStrategy,
}

impl VibeGuardGateStrategy {
    pub fn new(repo_dir: impl AsRef<Path>, mode: Option<&str>) -> Result<Self, regex::Error> {
        let hooks = HookRunner::new(repo_dir);
        Ok(Self {
            command_strategy: CommandApprovalStrategy {
                hooks: hooks.clone(),
                policy: GuardDecisionPolicy::new(mode),
                analysis: AnalysisParalysisStrategy::new()?,
            },
            file_change_strategy: FileChangeApprovalStrategy {
                hooks: hooks.clone(),
                policy: GuardDecisionPolicy::new(mode),
            },
            post_turn_strategy: PostTurnFeedbackStrategy { hooks },
        })
    }
}

impl GateStrategy for VibeGuardGateStrategy {
    fn on_client_message(&mut self, message: &Value, state: &mut SessionState) {
        let Some(method) = message.get("method").and_then(Value::as_str) else {
            return;
        };
        let Some(params) = message.get("params") else {
            return;
        };
        match method {
            "thread/start" | "turn/start" => {
                let Some(thread_id) = params.get("threadId").and_then(Value::as_str) else {
                    return;
                };
                let thread = state.ensure_thread(thread_id);
                if let Some(cwd) = params
                    .get("cwd")
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                {
                    thread.cwd = Some(cwd.into());
                }
                if method == "turn/start" {
                    if let Some(turn_id) = params
                        .get("turnId")
                        .and_then(Value::as_str)
                        .filter(|s| !s.is_empty())
                    {
                        thread.turn_id = Some(turn_id.into());
                    }
                }
            }
            _ => {}
        }
    }

    fn handle_server_request(
        &mut self,
        message: &Value,
        state: &mut SessionState,
        write_to_server: &mut WriteServer<'_>,
    ) -> bool {
        if self
            .command_strategy
            .handle(message, state, write_to_server)
        {
            return true;
        }
        self.file_change_strategy
            .handle(message, state, write_to_server)
    }

    fn on_server_notification(&mut self, message: Value, state: &mut SessionState) -> Value {
        self.file_change_strategy
            .on_server_notification(&message, state);
        if message.get("method").and_then(Value::as_str) != Some("turn/completed") {
            return message;
        }

        let Some(params) = message.get("params").and_then(Value::as_object) else {
            return message;
        };
        let Some(thread_id) = params.get("threadId").and_then(Value::as_str) else {
            return message;
        };
        let thread = state.ensure_thread(thread_id);
        if let Some(turn_id) = params
            .get("turnId")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            thread.turn_id = Some(turn_id.into());
        }
        let Some(cwd) = thread.cwd.clone() else {
            return message;
        };
        let Some(feedback) = self.post_turn_strategy.collect(&cwd, thread_id, thread) else {
            return message;
        };

        let mut next_message = message;
        if let Some(params) = next_message
            .get_mut("params")
            .and_then(Value::as_object_mut)
        {
            params.insert("vibeguard".into(), feedback);
        }
        next_message
    }
}
