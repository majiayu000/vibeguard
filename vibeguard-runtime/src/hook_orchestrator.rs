use serde_json::{Value, json};
use std::time::Instant;

use crate::event_schema::{decision, field, status, tool};
use crate::hook_checks_common::{append_jsonl, nested_str, read_stdin, truncate_chars};
use crate::hook_orchestrator_context::RuntimeContext;
use crate::time_utils::{format_unix_secs_utc, now_unix_secs};
use crate::wrapper_env::env_nonempty;

type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HookKind {
    PreWrite,
    PreBash,
    PreEdit,
    PostWrite,
    PostEdit,
    Stop,
    Learn,
}

impl HookKind {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "pre-write" | "pre-write-guard" => Some(Self::PreWrite),
            "pre-bash" | "pre-bash-guard" => Some(Self::PreBash),
            "pre-edit" | "pre-edit-guard" => Some(Self::PreEdit),
            "post-write" | "post-write-guard" => Some(Self::PostWrite),
            "post-edit" | "post-edit-guard" => Some(Self::PostEdit),
            "stop" | "stop-guard" => Some(Self::Stop),
            "learn" | "learn-evaluator" => Some(Self::Learn),
            _ => None,
        }
    }

    fn hook_name(self) -> &'static str {
        match self {
            Self::PreWrite => "pre-write-guard",
            Self::PreBash => "pre-bash-guard",
            Self::PreEdit => "pre-edit-guard",
            Self::PostWrite => "post-write-guard",
            Self::PostEdit => "post-edit-guard",
            Self::Stop => "stop-guard",
            Self::Learn => "learn-evaluator",
        }
    }

    fn tool_name(self) -> &'static str {
        match self {
            Self::PreWrite | Self::PostWrite => tool::WRITE,
            Self::PreBash => tool::BASH,
            Self::PreEdit | Self::PostEdit => tool::EDIT,
            Self::Stop | Self::Learn => "Stop",
        }
    }
}

pub(crate) fn run(args: &[String]) -> Result {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime hook <pre-write|pre-bash|pre-edit|post-write|post-edit|stop|learn>".into());
    }
    let kind = HookKind::parse(&args[0]).ok_or_else(|| format!("unknown hook: {}", args[0]))?;
    let start = Instant::now();
    let input = read_stdin()?;
    let ctx = RuntimeContext::collect()?;

    let parsed = serde_json::from_str::<Value>(&input);
    match parsed {
        Ok(data) if data.is_object() => {
            append_hook_event(
                &ctx,
                kind,
                decision::PASS,
                status::PASS,
                "runtime hook orchestrator scaffold",
                &detail_for(kind, &data),
                elapsed_ms(start),
            )?;
            Ok(())
        }
        _ => {
            let reason = format!(
                "VIBEGUARD interception: invalid {} hook input JSON; fail-closed because runtime hook orchestrator could not parse stdin.",
                kind.hook_name()
            );
            append_hook_event(
                &ctx,
                kind,
                decision::BLOCK,
                status::BLOCK,
                &reason,
                "",
                elapsed_ms(start),
            )?;
            println!(
                "{}",
                serde_json::to_string(&json!({
                    "decision": "block",
                    "reason": reason,
                }))?
            );
            Ok(())
        }
    }
}

fn append_hook_event(
    ctx: &RuntimeContext,
    kind: HookKind,
    decision_value: &str,
    status_value: &str,
    reason: &str,
    detail: &str,
    duration_ms: u64,
) -> Result {
    let mut event = json!({
        "schema_version": 1,
        field::TS: format_unix_secs_utc(now_unix_secs()),
        field::SESSION: ctx.session_id,
        field::HOOK: kind.hook_name(),
        field::TOOL: kind.tool_name(),
        field::DECISION: decision_value,
        field::STATUS: status_value,
        field::REASON: reason,
        field::DETAIL: truncate_chars(detail, 200),
        field::DURATION_MS: duration_ms,
        field::CLI: ctx.cli,
        field::CLIENT: ctx.client,
        field::CLIENT_VARIANT: ctx.client_variant,
        field::CALLER_EVIDENCE: ctx.caller_evidence,
    });
    event["project_hash"] = json!(ctx.project_hash);
    append_optional_env(&mut event, "VIBEGUARD_AGENT_TYPE", field::AGENT);
    append_optional_env(&mut event, "VIBEGUARD_WRAPPER", field::WRAPPER);
    append_optional_env(&mut event, "VIBEGUARD_SOURCE_CONFIG", field::SOURCE_CONFIG);
    append_optional_env(
        &mut event,
        "VIBEGUARD_HOOK_PROTOCOL_VERSION",
        field::HOOK_PROTOCOL_VERSION,
    );

    let line = serde_json::to_string(&event)?;
    append_jsonl(&ctx.log_file, &line)?;
    let global_log = ctx.log_root.join("events.jsonl");
    if global_log != ctx.log_file {
        append_jsonl(&global_log, &line)?;
    }
    Ok(())
}

fn append_optional_env(event: &mut Value, env_name: &str, field_name: &str) {
    if let Some(value) = env_nonempty(env_name) {
        event[field_name] = Value::String(value);
    }
}

fn detail_for(kind: HookKind, data: &Value) -> String {
    let path = match kind {
        HookKind::PreWrite | HookKind::PostWrite => nested_str(data, "tool_input.file_path"),
        HookKind::PreEdit | HookKind::PostEdit => {
            nested_str(data, "tool_input.file_path").or_else(|| nested_str(data, "tool_input.path"))
        }
        HookKind::PreBash => nested_str(data, "tool_input.command"),
        HookKind::Stop | HookKind::Learn => nested_str(data, "transcript_path"),
    };
    path.unwrap_or_default()
}

fn elapsed_ms(start: Instant) -> u64 {
    start.elapsed().as_millis().try_into().unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hook_kind_accepts_short_and_script_names() {
        assert_eq!(HookKind::parse("pre-write"), Some(HookKind::PreWrite));
        assert_eq!(HookKind::parse("pre-write-guard"), Some(HookKind::PreWrite));
        assert_eq!(HookKind::parse("nope"), None);
    }
}
