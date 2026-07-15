use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use crate::circuit_breaker::{self, CircuitCheckOutcome, CircuitRecordBlockOutcome};
use crate::event_schema::{decision, field, status, tool};
use crate::hook_checks::{PreWriteCheck, evaluate_pre_write_input};
use crate::hook_checks_common::{append_jsonl, nested_str, read_stdin, truncate_chars};
use crate::hook_orchestrator_context::RuntimeContext;
use crate::runtime_config::{runtime_config_int_value, runtime_config_str_value};
use crate::time_utils::{format_unix_secs_utc, now_unix_secs};
use crate::wrapper_env::env_nonempty;

pub(crate) type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;

const EVENT_DETAIL_MAX_CHARS: usize = 200;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum HookKind {
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
    if kind == HookKind::PreWrite {
        let ctx = match RuntimeContext::collect() {
            Ok(ctx) => ctx,
            Err(err) => {
                emit_runtime_failure_block(kind, "collect runtime context", err)?;
                return Ok(());
            }
        };
        run_pre_write(&ctx, &input, start)?;
        return Ok(());
    }
    if kind == HookKind::PreBash {
        let ctx = match RuntimeContext::collect() {
            Ok(ctx) => ctx,
            Err(err) => {
                emit_runtime_failure_block(kind, "collect runtime context", err)?;
                return Ok(());
            }
        };
        crate::hook_orchestrator_pre_bash::run(&ctx, &input, start)?;
        return Ok(());
    }
    if kind == HookKind::PreEdit {
        let ctx = match RuntimeContext::collect() {
            Ok(ctx) => ctx,
            Err(err) => {
                emit_runtime_failure_block(kind, "collect runtime context", err)?;
                return Ok(());
            }
        };
        crate::hook_orchestrator_pre_edit::run(&ctx, &input, start)?;
        return Ok(());
    }
    if kind == HookKind::PostWrite {
        let ctx = match RuntimeContext::collect() {
            Ok(ctx) => ctx,
            Err(err) => {
                emit_runtime_failure_block(kind, "collect runtime context", err)?;
                return Ok(());
            }
        };
        crate::hook_orchestrator_post_write::run(&ctx, &input, start)?;
        return Ok(());
    }
    if kind == HookKind::PostEdit {
        let ctx = match RuntimeContext::collect() {
            Ok(ctx) => ctx,
            Err(err) => {
                emit_runtime_failure_block(kind, "collect runtime context", err)?;
                return Ok(());
            }
        };
        crate::hook_orchestrator_post_edit::run(&ctx, &input, start)?;
        return Ok(());
    }
    if kind == HookKind::Stop {
        crate::hook_orchestrator_stop::run(&input, start)?;
        return Ok(());
    }
    if kind == HookKind::Learn {
        crate::hook_orchestrator_learn::run(&input, start)?;
        return Ok(());
    }

    let parsed = serde_json::from_str::<Value>(&input);
    match parsed {
        Ok(data) if data.is_object() => {
            let ctx = match RuntimeContext::collect() {
                Ok(ctx) => ctx,
                Err(err) => {
                    emit_runtime_failure_block(kind, "collect runtime context", err)?;
                    return Ok(());
                }
            };
            if let Err(err) = append_hook_event(
                &ctx,
                kind,
                decision::PASS,
                status::PASS,
                "runtime hook orchestrator scaffold",
                &detail_for(kind, &data),
                elapsed_ms(start),
            ) {
                emit_runtime_failure_block(kind, "append hook event", err)?;
            }
            Ok(())
        }
        _ => {
            let reason = format!(
                "VIBEGUARD interception: invalid {} hook input JSON; fail-closed because runtime hook orchestrator could not parse stdin.",
                kind.hook_name()
            );
            print_block(&reason)?;
            match RuntimeContext::collect() {
                Ok(ctx) => {
                    if let Err(err) = append_hook_event(
                        &ctx,
                        kind,
                        decision::BLOCK,
                        status::BLOCK,
                        &reason,
                        "",
                        elapsed_ms(start),
                    ) {
                        eprintln!(
                            "VIBEGUARD: failed to log fail-closed {} event: {err}",
                            kind.hook_name()
                        );
                    }
                }
                Err(err) => {
                    eprintln!(
                        "VIBEGUARD: failed to collect context for fail-closed {} event: {err}",
                        kind.hook_name()
                    );
                }
            }
            Ok(())
        }
    }
}

fn run_pre_write(ctx: &RuntimeContext, input: &str, start: Instant) -> Result {
    let base_limit = runtime_config_int_value("VG_U16_LIMIT", "u16.limit", "800") as usize;
    let warn_limit = u16_warn_limit(base_limit);
    let check = evaluate_pre_write_input(input, base_limit, warn_limit);

    match &check {
        PreWriteCheck::Malformed => {
            append_hook_event(
                ctx,
                HookKind::PreWrite,
                decision::BLOCK,
                status::BLOCK,
                "Malformed hook input",
                "",
                elapsed_ms(start),
            )?;
            print_pretty_decision("block", MALFORMED_PRE_WRITE_REASON);
        }
        PreWriteCheck::Exists { .. } | PreWriteCheck::Allow { .. } => {
            pass_and_exit(ctx, start)?;
        }
        PreWriteCheck::W12 { file_path } => {
            append_hook_event(
                ctx,
                HookKind::PreWrite,
                decision::BLOCK,
                status::BLOCK,
                "Test Infrastructure File Guard (W-12)",
                file_path,
                elapsed_ms(start),
            )?;
            print_pretty_decision("block", W12_PRE_WRITE_REASON);
        }
        PreWriteCheck::U16Block {
            file_path,
            line_count,
            limit,
        } => {
            append_hook_event(
                ctx,
                HookKind::PreWrite,
                decision::BLOCK,
                status::BLOCK,
                &format!("U-16 file size: {line_count} > {limit}"),
                file_path,
                elapsed_ms(start),
            )?;
            print_pretty_decision(
                "block",
                &format!(
                    "VIBEGUARD [U-16] block: writing {} with {line_count} lines exceeds the {limit}-line limit. Split into focused submodules first. Do NOT proceed with this write.",
                    file_name(file_path)
                ),
            );
        }
        PreWriteCheck::U16Warn {
            file_path,
            line_count,
            warn_limit,
            limit,
        } => {
            append_hook_event(
                ctx,
                HookKind::PreWrite,
                decision::WARN,
                status::WARN,
                &format!("U-16 file size advisory: {line_count} > {warn_limit}"),
                file_path,
                elapsed_ms(start),
            )?;
            print_hook_context(&u16_advisory_context(
                file_path,
                *line_count,
                *warn_limit,
                *limit,
                false,
            ))?;
        }
        PreWriteCheck::U16WarnSourceNew { .. } => {
            run_source_new(ctx, start, &check, true)?;
        }
        PreWriteCheck::SourceNew { .. } => {
            run_source_new(ctx, start, &check, false)?;
        }
    }

    Ok(())
}

fn run_source_new(
    ctx: &RuntimeContext,
    start: Instant,
    check: &PreWriteCheck,
    has_u16_advisory: bool,
) -> Result {
    let file_path = match check {
        PreWriteCheck::SourceNew { file_path }
        | PreWriteCheck::U16WarnSourceNew { file_path, .. } => file_path,
        _ => return pass_and_exit(ctx, start),
    };
    let mode = write_mode();
    if mode == "block" {
        append_hook_event(
            ctx,
            HookKind::PreWrite,
            decision::BLOCK,
            status::BLOCK,
            "New source code file not searched",
            file_path,
            elapsed_ms(start),
        )?;
        print_pretty_decision("block", L1_BLOCK_REASON);
        return Ok(());
    }

    let threshold = runtime_config_int_value(
        "VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD",
        "write_escalate_threshold",
        "5",
    );
    let prior_count = if threshold > 0 {
        count_recent_source_new_attempts(ctx).unwrap_or(0)
    } else {
        0
    };
    if threshold > 0 && prior_count >= threshold {
        append_hook_event(
            ctx,
            HookKind::PreWrite,
            decision::ESCALATE,
            status::ESCALATE,
            &format!("L1 escalation after {prior_count} unheeded source-new attempts"),
            file_path,
            elapsed_ms(start),
        )?;
        print_pretty_decision(
            "block",
            &format!(
                "VIBEGUARD [L1] [block] [escalation] OBSERVATION: {prior_count} new source file attempts in this session went unheeded\nSCOPE: pause new file creation — run Grep for similar function/class names and Glob for same-named files in this repo before any further Write\nACTION: REVIEW — confirm no duplicate exists; after manual verification start a new session, raise VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD, or export VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD=0 to disable escalation for this session"
            ),
        );
        return Ok(());
    }

    append_hook_event(
        ctx,
        HookKind::PreWrite,
        decision::WARN,
        status::WARN,
        "New source file attempt",
        file_path,
        elapsed_ms(start),
    )?;

    let breaker = breaker_config(ctx, "pre-write-guard");
    match circuit_breaker::check(
        &breaker.state_file,
        &breaker.lock_file,
        breaker.cooldown,
        breaker.lock_timeout,
        &ctx.session_id,
    ) {
        Ok(CircuitCheckOutcome::Run) => {
            append_hook_event(
                ctx,
                HookKind::PreWrite,
                decision::WARN,
                status::WARN,
                "New source file reminder",
                file_path,
                elapsed_ms(start),
            )?;
            match circuit_breaker::record_block(
                &breaker.state_file,
                &breaker.lock_file,
                breaker.threshold,
                breaker.cooldown,
                breaker.lock_timeout,
                &ctx.session_id,
            ) {
                Ok(CircuitRecordBlockOutcome::Recorded) => {}
                Ok(CircuitRecordBlockOutcome::Opened { reason }) => {
                    append_event(
                        ctx,
                        "pre-write-guard",
                        "circuit-breaker",
                        (decision::WARN, None),
                        &reason,
                        ("", EVENT_DETAIL_MAX_CHARS),
                        elapsed_ms(start),
                    )?;
                }
                Err(_) => {
                    append_hook_event(
                        ctx,
                        HookKind::PreWrite,
                        decision::BLOCK,
                        status::BLOCK,
                        "Circuit breaker state error; fail-closed",
                        file_path,
                        elapsed_ms(start),
                    )?;
                    print_policy_decision_kv(
                        "block",
                        "VIBEGUARD interception: pre-write circuit breaker state could not be persisted; fail-closed instead of silently continuing.",
                    );
                    return Ok(());
                }
            }
            print_hook_context(&source_new_context(check, has_u16_advisory))?;
        }
        Ok(CircuitCheckOutcome::AutoPass { reason }) => {
            append_event(
                ctx,
                "pre-write-guard",
                "circuit-breaker",
                (decision::PASS, None),
                &reason,
                ("", EVENT_DETAIL_MAX_CHARS),
                elapsed_ms(start),
            )?;
        }
        Err(_) => {
            append_hook_event(
                ctx,
                HookKind::PreWrite,
                decision::BLOCK,
                status::BLOCK,
                "Circuit breaker state error; fail-closed",
                file_path,
                elapsed_ms(start),
            )?;
            print_policy_decision_kv(
                "block",
                "VIBEGUARD interception: pre-write circuit breaker state could not be read; fail-closed instead of silently auto-passing.",
            );
        }
    }

    Ok(())
}

fn pass_and_exit(ctx: &RuntimeContext, start: Instant) -> Result {
    let breaker = breaker_config(ctx, "pre-write-guard");
    if circuit_breaker::record_pass(
        &breaker.state_file,
        &breaker.lock_file,
        breaker.lock_timeout,
        &ctx.session_id,
    )
    .is_err()
    {
        append_hook_event(
            ctx,
            HookKind::PreWrite,
            decision::BLOCK,
            status::BLOCK,
            "Circuit breaker state error; fail-closed",
            "",
            elapsed_ms(start),
        )?;
        print_policy_decision_kv(
            "block",
            "VIBEGUARD interception: pre-write circuit breaker state could not be updated; fail-closed instead of silently continuing.",
        );
    }
    Ok(())
}

fn u16_warn_limit(base_limit: usize) -> usize {
    let configured =
        runtime_config_int_value("VG_U16_WARN_LIMIT", "u16.warn_limit", "400") as usize;
    configured.min(base_limit)
}

fn write_mode() -> String {
    match runtime_config_str_value("VIBEGUARD_WRITE_MODE", "write_mode", "warn").as_str() {
        "block" => "block".to_string(),
        _ => "warn".to_string(),
    }
}

struct BreakerConfig {
    state_file: PathBuf,
    lock_file: PathBuf,
    threshold: u64,
    cooldown: u64,
    lock_timeout: u64,
}

fn breaker_config(ctx: &RuntimeContext, hook: &str) -> BreakerConfig {
    let state_file = ctx
        .log_root
        .join("circuit-breaker")
        .join(&ctx.project_hash)
        .join(format!("{hook}.cb"));
    let lock_file = PathBuf::from(format!("{}.lock", state_file.display()));
    BreakerConfig {
        state_file,
        lock_file,
        threshold: runtime_config_int_value("VG_CB_THRESHOLD", "circuit_breaker.threshold", "3"),
        cooldown: runtime_config_int_value(
            "VG_CB_COOLDOWN",
            "circuit_breaker.cooldown_seconds",
            "300",
        ),
        lock_timeout: runtime_config_int_value(
            "VG_CB_LOCK_TIMEOUT_SECONDS",
            "circuit_breaker.lock_timeout_seconds",
            "5",
        ),
    }
}

fn count_recent_source_new_attempts(ctx: &RuntimeContext) -> Result<u64> {
    let text = match fs::read_to_string(&ctx.log_file) {
        Ok(text) => text,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(err) => return Err(err.into()),
    };
    let count = text
        .lines()
        .rev()
        .take(500)
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|event| {
            event.get(field::SESSION).and_then(Value::as_str) == Some(ctx.session_id.as_str())
                && event.get(field::HOOK).and_then(Value::as_str) == Some("pre-write-guard")
                && event.get(field::REASON).and_then(Value::as_str)
                    == Some("New source file attempt")
        })
        .count();
    Ok(count as u64)
}

const MALFORMED_PRE_WRITE_REASON: &str = "VIBEGUARD interception: malformed PreToolUse(Write) hook input. The write request could not be validated, so it was blocked instead of being treated as a safe skip.";
const W12_PRE_WRITE_REASON: &str = "[W-12] [block] [this-edit] OBSERVATION: writing to test infrastructure file blocked (conftest.py/jest.config/pytest.ini/.coveragerc/babel.config)\nFIX: Fix the production code that is failing — do not manipulate test framework configuration";
const L1_BLOCK_REASON: &str = "VIBEGUARD [L1] [block] [this-edit] OBSERVATION: new source file creation blocked — search not performed before write\nSCOPE: search required before retry — use Grep for functions/classes/structs, Glob for same-named files\nACTION: REVIEW";

fn emit_runtime_failure_block(
    kind: HookKind,
    operation: &str,
    err: Box<dyn std::error::Error>,
) -> Result {
    let reason = format!(
        "VIBEGUARD interception: {} runtime orchestrator failed to {}; fail-closed.",
        kind.hook_name(),
        operation
    );
    print_block(&reason)?;
    eprintln!("VIBEGUARD: {reason}: {err}");
    Ok(())
}

fn print_block(reason: &str) -> Result {
    println!(
        "{}",
        serde_json::to_string(&json!({
            "decision": "block",
            "reason": reason,
        }))?
    );
    Ok(())
}

pub(crate) fn append_hook_event(
    ctx: &RuntimeContext,
    kind: HookKind,
    decision_value: &str,
    _status_value: &str,
    reason: &str,
    detail: &str,
    duration_ms: u64,
) -> Result {
    append_event(
        ctx,
        kind.hook_name(),
        kind.tool_name(),
        (decision_value, None),
        reason,
        (detail, EVENT_DETAIL_MAX_CHARS),
        duration_ms,
    )
}

pub(crate) fn append_hook_event_with_status(
    ctx: &RuntimeContext,
    kind: HookKind,
    decision_value: &str,
    status_value: &str,
    reason: &str,
    detail: (&str, usize),
    duration_ms: u64,
) -> Result {
    append_event(
        ctx,
        kind.hook_name(),
        kind.tool_name(),
        (decision_value, Some(status_value)),
        reason,
        detail,
        duration_ms,
    )
}

fn append_event(
    ctx: &RuntimeContext,
    hook_name: &str,
    tool_name: &str,
    outcome: (&str, Option<&str>),
    reason: &str,
    detail: (&str, usize),
    duration_ms: u64,
) -> Result {
    let (decision_value, status_value) = outcome;
    let (detail, detail_max_chars) = detail;
    let (decision_value, reason) = log_policy_decision(decision_value, reason);
    let status_value = status_value.unwrap_or(&decision_value);
    let mut event = json!({
        "schema_version": 1,
        field::TS: format_unix_secs_utc(now_unix_secs()),
        field::SESSION: ctx.session_id,
        field::HOOK: hook_name,
        field::TOOL: tool_name,
        field::DECISION: decision_value,
        field::STATUS: status_value,
        field::REASON: reason,
        field::DETAIL: truncate_chars(detail, detail_max_chars),
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

    let line = serde_json::to_string(&event)?.replace("\":", "\": ");
    append_jsonl(&ctx.log_file, &line)?;
    let global_log = ctx.log_root.join("events.jsonl");
    if global_log != ctx.log_file {
        append_jsonl(&global_log, &line)?;
    }
    Ok(())
}

fn log_policy_decision(decision_value: &str, reason: &str) -> (String, String) {
    if env_nonempty("VIBEGUARD_POLICY_ENFORCEMENT").as_deref() == Some("warn")
        && matches!(
            decision_value,
            decision::BLOCK | "gate" | decision::ESCALATE
        )
    {
        (
            decision::WARN.to_string(),
            format!("warn-mode advisory: {reason}"),
        )
    } else {
        (decision_value.to_string(), reason.to_string())
    }
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

pub(crate) fn elapsed_ms(start: Instant) -> u64 {
    start.elapsed().as_millis().try_into().unwrap_or(u64::MAX)
}

fn print_pretty_decision(decision_value: &str, reason: &str) {
    println!("{{");
    println!("  \"decision\": \"{decision_value}\",");
    println!(
        "  \"reason\": {}",
        serde_json::to_string(reason).unwrap_or_else(|_| "\"\"".to_string())
    );
    println!("}}");
}

pub(crate) fn print_policy_decision_kv(decision_value: &str, reason: &str) {
    let output_decision = if env_nonempty("VIBEGUARD_POLICY_ENFORCEMENT").as_deref() == Some("warn")
        && matches!(
            decision_value,
            decision::BLOCK | "gate" | decision::ESCALATE
        ) {
        decision::WARN
    } else {
        decision_value
    };
    println!(
        "{{ \"decision\": {}, \"reason\": {} }}",
        serde_json::to_string(output_decision).unwrap_or_else(|_| "\"block\"".to_string()),
        serde_json::to_string(reason).unwrap_or_else(|_| "\"\"".to_string())
    );
}

fn print_hook_context(context: &str) -> Result {
    println!(
        "{}",
        serde_json::to_string(&json!({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "additionalContext": context,
            }
        }))?
    );
    Ok(())
}

fn source_new_context(check: &PreWriteCheck, has_u16_advisory: bool) -> String {
    if has_u16_advisory
        && let PreWriteCheck::U16WarnSourceNew {
            file_path,
            line_count,
            warn_limit,
            limit,
        } = check
    {
        return u16_advisory_context(file_path, *line_count, *warn_limit, *limit, true);
    }
    L1_ADVISORY_CONTEXT.to_string()
}

fn u16_advisory_context(
    file_path: &str,
    line_count: usize,
    warn_limit: usize,
    limit: usize,
    include_search: bool,
) -> String {
    let mut context = format!(
        "VIBEGUARD [U-16] [advisory] [this-file] OBSERVATION: writing {} with {line_count} lines exceeds the {warn_limit}-line typical range but stays under the {limit}-line hard limit\nSCOPE: keep the current change localized; plan a split if this file keeps growing\nACTION: NONE — advisory only, continue without acknowledgement",
        file_name(file_path)
    );
    if include_search {
        context.push_str("\n---\n");
        context.push_str(L1_ADVISORY_CONTEXT);
    }
    context
}

fn file_name(path: &str) -> &str {
    Path::new(path)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(path)
}

const L1_ADVISORY_CONTEXT: &str = "VIBEGUARD [L1] [advisory] [this-edit] OBSERVATION: new source file detected — search for similar implementation before adding duplicates\nSCOPE: if not yet checked, consider Grep for functions/classes/structs and Glob for same-named files\nACTION: NONE — advisory only, continue without acknowledgement";

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
