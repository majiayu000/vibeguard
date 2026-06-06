mod circuit_breaker;
mod codex_app_server;
mod codex_app_server_core;
mod codex_app_server_file_changes;
mod codex_app_server_policy;
mod codex_app_server_strategies;
mod codex_hooks;
mod event_schema;
mod git_root;
mod hook_checks;
mod hook_checks_bash;
mod hook_checks_common;
mod hook_checks_history;
mod hook_checks_scan;
mod hook_checks_write;
mod hook_checks_write_scan;
mod hook_status;
mod json_field;
mod log_append;
mod log_query;
mod log_scope;
mod observe;
mod pkg_rewrite;
mod project_config;
mod runtime_config;
mod runtime_policy;
mod session_metrics;
mod time_utils;

use std::env;
use std::process;

type HandlerResult = std::result::Result<(), Box<dyn std::error::Error>>;

struct Command {
    name: &'static str,
    usage: &'static str,
    handler: fn(&[String]) -> HandlerResult,
}

static COMMANDS: &[Command] = &[
    Command {
        name: "json-field",
        usage: "<field_path>  — extract one field from stdin JSON",
        handler: json_field::run_field,
    },
    Command {
        name: "json-two-fields",
        usage: "<field1> <field2>  — extract two fields from stdin JSON",
        handler: json_field::run_two_fields,
    },
    Command {
        name: "churn-count",
        usage: "<session> <file>  — count Edit events for a file",
        handler: log_query::churn_count,
    },
    Command {
        name: "warn-count",
        usage: "<session> <file>  — count warn events for a file",
        handler: log_query::warn_count,
    },
    Command {
        name: "post-edit-history",
        usage: "<session> <file> [agent]  — summarize post-edit history signals",
        handler: log_query::post_edit_history,
    },
    Command {
        name: "build-fails",
        usage: "<session> <project>  — count consecutive build failures",
        handler: log_query::build_fails,
    },
    Command {
        name: "paralysis-count",
        usage: "<session>  — count consecutive read-only tool calls",
        handler: log_query::paralysis_count,
    },
    Command {
        name: "append-jsonl",
        usage: "<log-file>  — append one stdin JSONL line with runtime locking",
        handler: log_append::run,
    },
    Command {
        name: "circuit-breaker",
        usage: "<check|record-block|record-pass> <hook> <state-file> <lock-file> <threshold> <cooldown> <lock-timeout>  — update hook circuit breaker state with runtime locking",
        handler: circuit_breaker::run,
    },
    Command {
        name: "pkg-rewrite",
        usage: "  — rewrite package manager command from stdin",
        handler: pkg_rewrite::run,
    },
    Command {
        name: "pre-bash-check",
        usage: "<vibeguard-root>  — classify PreToolUse(Bash) input for hooks",
        handler: hook_checks_bash::pre_bash_check,
    },
    Command {
        name: "session-metrics",
        usage: "<session> <dir>  — emit session metrics and correction signals",
        handler: session_metrics::run,
    },
    Command {
        name: "observe",
        usage: "<summary|health|session|export prometheus> [options]  — query observability summaries or export low-cardinality metrics",
        handler: observe::run,
    },
    Command {
        name: "hook-status",
        usage: "[--mode minimal|focused|full] [--json] [--scope project|global] [--project PATH_OR_HASH] [--log-file PATH] [--diag-file PATH]  — summarize hook pass/skip/warn/timeout status without adding model context",
        handler: hook_status::run,
    },
    Command {
        name: "codex-event-name",
        usage: "  — extract hook_event_name from Codex hook stdin",
        handler: codex_hooks::event_name,
    },
    Command {
        name: "codex-status-detail",
        usage: "  — extract Codex hook status detail from stdin",
        handler: codex_hooks::status_detail,
    },
    Command {
        name: "codex-status-matcher",
        usage: "  — extract Codex hook status matcher from stdin",
        handler: codex_hooks::status_matcher,
    },
    Command {
        name: "codex-status-from-output",
        usage: "  — classify wrapped hook output status from stdin",
        handler: codex_hooks::status_from_output,
    },
    Command {
        name: "codex-pretool-deny",
        usage: "  — emit a Codex PreToolUse deny payload from stdin reason",
        handler: codex_hooks::deny_pretool,
    },
    Command {
        name: "codex-permission-deny",
        usage: "  — emit a Codex PermissionRequest deny payload from stdin reason",
        handler: codex_hooks::deny_permission,
    },
    Command {
        name: "codex-adapt-pretool",
        usage: "  — adapt wrapped hook output to Codex PreToolUse JSON",
        handler: codex_hooks::adapt_pretool,
    },
    Command {
        name: "codex-adapt-posttool",
        usage: "  — adapt wrapped hook output to Codex PostToolUse JSON",
        handler: codex_hooks::adapt_posttool,
    },
    Command {
        name: "codex-adapt-permission-request",
        usage: "  — adapt wrapped hook output to Codex PermissionRequest JSON",
        handler: codex_hooks::adapt_permission_request,
    },
    Command {
        name: "codex-normalize-apply-patch",
        usage: "<hook-name>  — normalize Codex apply_patch payloads for file hooks",
        handler: codex_hooks::normalize_apply_patch,
    },
    Command {
        name: "runtime-policy-check",
        usage: "<hook-name>  — evaluate runtime hook policy and config",
        handler: runtime_policy::runtime_policy_check,
    },
    Command {
        name: "runtime-policy-downgrade-output",
        usage: "  — downgrade stdin hook JSON to warn-mode advisory output",
        handler: runtime_policy::runtime_policy_downgrade_output,
    },
    Command {
        name: "runtime-policy-codex-error",
        usage: "<event-name>  — emit Codex-visible policy error JSON from stdin reason",
        handler: runtime_policy::runtime_policy_codex_error,
    },
    Command {
        name: "runtime-policy-diag",
        usage: "<diag-file> <hook-name> <event-name> <kind> <wrapper>  — append policy diagnostic JSONL from stdin reason",
        handler: runtime_policy::runtime_policy_diag,
    },
    Command {
        name: "runtime-config-get-int",
        usage: "<env-name> <json-path> <default>  — read an integer from runtime config",
        handler: runtime_config::runtime_config_get_int,
    },
    Command {
        name: "runtime-config-get-str",
        usage: "<env-name> <json-path> <default>  — read a string from runtime config",
        handler: runtime_config::runtime_config_get_str,
    },
    Command {
        name: "project-config-validate",
        usage: "<config-file>  — validate a project .vibeguard.json file",
        handler: project_config::project_config_validate,
    },
    Command {
        name: "project-config-value",
        usage: "<config-file> <json-path> <default>  — read a value from project config",
        handler: project_config::project_config_value,
    },
    Command {
        name: "pre-write-check",
        usage: "<base-limit> [warn-limit]  — classify PreToolUse(Write) input for hooks",
        handler: hook_checks::pre_write_check,
    },
    Command {
        name: "pre-edit-check",
        usage: "<base-limit> [warn-limit] <log-file>  — classify and handle PreToolUse(Edit) input for hooks",
        handler: hook_checks::pre_edit_check,
    },
    Command {
        name: "post-edit-fast-check",
        usage: "<base-limit> <session> <agent> <log-file>  — fast-pass clean PostToolUse(Edit) inputs",
        handler: hook_checks::post_edit_fast_check,
    },
    Command {
        name: "post-write-fast-check",
        usage: "<base-limit> <max-scan-files> <log-file>  — fast-pass simple PostToolUse(Write) inputs",
        handler: hook_checks::post_write_fast_check,
    },
    Command {
        name: "post-write-check",
        usage: "<base-limit> <warn-limit> <max-scan-files> <max-scan-defs> <max-matches> <log-file>  — classify and handle PostToolUse(Write) input for hooks",
        handler: hook_checks_write::post_write_check,
    },
    Command {
        name: "codex-app-server-wrapper",
        usage: "[--repo-dir DIR] [--strategy vibeguard|noop] [--codex-command CMD]  — run the Rust Codex app-server guard proxy",
        handler: codex_app_server::run,
    },
];

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: vibeguard-runtime <command> [args...]");
        for cmd in COMMANDS {
            eprintln!("  {}  {}", cmd.name, cmd.usage);
        }
        process::exit(2);
    }

    match COMMANDS.iter().find(|c| c.name == args[1].as_str()) {
        None => {
            eprintln!("Unknown command: {}", args[1]);
            process::exit(2);
        }
        Some(cmd) => {
            if let Err(e) = (cmd.handler)(&args[2..]) {
                eprintln!("vibeguard-runtime error: {e}");
                process::exit(1);
            }
        }
    }
}
