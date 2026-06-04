use crate::codex_app_server_core::{
    GateStrategy, GuardDecisionPolicy, HookRunner, SessionState, ThreadState, WriteServer,
    capabilities, emit_warning, feedback_messages, hook_env, primary_feedback_text,
};
use crate::codex_app_server_file_changes::{
    FileChangeApprovalStrategy, attach_vibeguard_feedback, params_thread_id, params_turn_id,
};
use crate::codex_app_server_policy::{HookPolicyDecision, evaluate_hook_policy};
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
            self.observe(
                command,
                thread_id.as_deref(),
                cwd.as_deref(),
                &env,
                state,
                write_to_server,
            );
            return false;
        }

        if result.decision == "skip" {
            let text = primary_feedback_text("pre-bash-guard.sh", &result, "");
            emit_warning(write_to_server, text, thread_id.as_deref());
            self.observe(
                command,
                thread_id.as_deref(),
                cwd.as_deref(),
                &env,
                state,
                write_to_server,
            );
            return false;
        }

        if !matches!(
            result.decision.as_str(),
            "pass" | "allow" | "block" | "hook_error" | "skip"
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
                "result": {"decision": "accept", "updatedInput": {"command": updated_command}}
            }));
            eprintln!(
                "[vibeguard-codex-wrapper] corrected command: {command:?} -> {updated_command:?}"
            );
            self.observe(
                &updated_command,
                thread_id.as_deref(),
                cwd.as_deref(),
                &env,
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

        self.observe(
            command,
            thread_id.as_deref(),
            cwd.as_deref(),
            &env,
            state,
            write_to_server,
        );
        false
    }

    fn observe(
        &self,
        command: &str,
        thread_id: Option<&str>,
        cwd: Option<&str>,
        env: &std::collections::HashMap<String, String>,
        state: &mut SessionState,
        write_to_server: &mut WriteServer<'_>,
    ) {
        match evaluate_hook_policy("analysis-paralysis-guard.sh", cwd, env) {
            HookPolicyDecision::Run { .. } => {}
            HookPolicyDecision::Skip(_) => return,
            HookPolicyDecision::Error(reason) => {
                emit_warning(
                    write_to_server,
                    format!("analysis-paralysis-guard.sh: {reason}"),
                    thread_id,
                );
                return;
            }
        }
        let thread = thread_id.map(|id| state.ensure_thread(id));
        self.analysis
            .observe_command(command, thread_id, thread, write_to_server);
    }
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
            file_change_strategy: FileChangeApprovalStrategy::new(
                hooks.clone(),
                GuardDecisionPolicy::new(mode),
            ),
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
        let file_feedback = self
            .file_change_strategy
            .on_server_notification(&message, state);
        if message.get("method").and_then(Value::as_str) != Some("turn/completed") {
            return file_feedback
                .map(|feedback| attach_vibeguard_feedback(message.clone(), feedback))
                .unwrap_or(message);
        }

        let Some(params) = message.get("params") else {
            return message;
        };
        let Some(thread_id) = params_thread_id(params) else {
            return message;
        };
        let thread = state.ensure_thread(thread_id);
        if let Some(turn_id) = params_turn_id(params).filter(|s| !s.is_empty()) {
            thread.turn_id = Some(turn_id.into());
        }
        let Some(cwd) = thread.cwd.clone() else {
            return message;
        };
        let Some(feedback) = self.post_turn_strategy.collect(&cwd, thread_id, thread) else {
            return message;
        };

        attach_vibeguard_feedback(message, feedback)
    }
}

#[cfg(test)]
#[path = "codex_app_server_profile_tests.rs"]
mod profile_tests;

#[cfg(test)]
#[path = "codex_app_server_strategies_tests.rs"]
mod tests;
