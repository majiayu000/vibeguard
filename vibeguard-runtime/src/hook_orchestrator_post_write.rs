use serde_json::{Value, json};
use std::path::PathBuf;
use std::time::Instant;

use crate::event_schema::{decision, status};
use crate::hook_checks_common::nested_str;
use crate::hook_checks_write::{
    PostWriteConfig, PostWriteOutcome, evaluate_post_write, post_write_warning_output,
};
use crate::hook_orchestrator::{HookKind, Result, append_hook_event, elapsed_ms};
use crate::hook_orchestrator_context::RuntimeContext;
use crate::runtime_config::runtime_config_int_value;

pub(crate) fn run(ctx: &RuntimeContext, input: &str, start: Instant) -> Result {
    let data = match serde_json::from_str::<Value>(input) {
        Ok(data) => data,
        Err(_) => {
            let context = "VIBEGUARD ERROR: malformed PostToolUse(Write) hook input. The write result could not be inspected, so this warning is reported visibly instead of silently passing.";
            let _ = append_hook_event(
                ctx,
                HookKind::PostWrite,
                decision::WARN,
                status::WARN,
                "Malformed hook input",
                "",
                elapsed_ms(start),
            );
            print_context(context)?;
            return Ok(());
        }
    };

    let file_path = nested_str(&data, "tool_input.file_path").unwrap_or_default();
    let content = nested_str(&data, "tool_input.content").unwrap_or_default();
    if file_path.is_empty() || content.is_empty() {
        return Ok(());
    }

    let base_limit = runtime_config_int_value("VG_U16_LIMIT", "u16.limit", "800") as usize;
    let config = PostWriteConfig {
        base_limit,
        warn_limit: (runtime_config_int_value("VG_U16_WARN_LIMIT", "u16.warn_limit", "400")
            as usize)
            .min(base_limit),
        max_scan_files: env_usize("VG_SCAN_MAX_FILES", 5000),
        max_scan_defs: env_usize("VG_SCAN_MAX_DEFS", 20),
        max_matches: env_usize("VG_SCAN_MATCH_LIMIT", 5),
    };

    match evaluate_post_write(&file_path, &content, config) {
        PostWriteOutcome::Pass { reason } => {
            if let Err(err) = append_hook_event(
                ctx,
                HookKind::PostWrite,
                decision::PASS,
                status::PASS,
                reason,
                &file_path,
                elapsed_ms(start),
            ) {
                print_context(&internal_context(ctx, &err.to_string()))?;
            }
        }
        PostWriteOutcome::Warn { warnings } => {
            if let Err(err) = append_hook_event(
                ctx,
                HookKind::PostWrite,
                decision::WARN,
                status::WARN,
                &warnings,
                &file_path,
                elapsed_ms(start),
            ) {
                print_context(&internal_context(ctx, &err.to_string()))?;
            } else {
                println!("{}", post_write_warning_output(&warnings)?);
            }
        }
    }

    Ok(())
}

fn env_usize(name: &str, fallback: usize) -> usize {
    std::env::var(name)
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(fallback)
}

fn print_context(context: &str) -> Result {
    println!(
        "{}",
        serde_json::to_string(&json!({
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": context,
            }
        }))?
    );
    Ok(())
}

fn internal_context(ctx: &RuntimeContext, detail: &str) -> String {
    let log_path = post_write_failure_log_path(ctx);
    let lock_path = PathBuf::from(format!("{}.lock.d", log_path.display()));
    let failure_kind = if lock_path.is_dir() {
        "lock"
    } else {
        "runtime"
    };
    let recovery = if failure_kind == "lock" {
        format!(
            "if no VibeGuard hook is active, run: rmdir \"{}\"",
            lock_path.display()
        )
    } else {
        "bash scripts/hook-health.sh 24".to_string()
    };
    format!(
        "VIBEGUARD internal error [VG-INTERNAL-POST-WRITE-RUNTIME]: hook=post-write-guard tool=Write failure_kind={failure_kind} mode=warn project={} session={} log_path={} recovery={recovery} detail=post-write runtime check failed: {detail}",
        ctx.project_hash,
        ctx.session_id,
        log_path.display()
    )
}

fn post_write_failure_log_path(ctx: &RuntimeContext) -> PathBuf {
    let project_lock = PathBuf::from(format!("{}.lock.d", ctx.log_file.display()));
    if project_lock.is_dir() {
        return ctx.log_file.clone();
    }
    let global_log = ctx.log_root.join("events.jsonl");
    let global_lock = PathBuf::from(format!("{}.lock.d", global_log.display()));
    if global_lock.is_dir() {
        return global_log;
    }
    ctx.log_file.clone()
}
