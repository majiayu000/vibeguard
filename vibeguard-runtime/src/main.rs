mod active_constraints;
mod circuit_breaker;
mod codex_app_server;
mod codex_app_server_core;
mod codex_app_server_file_changes;
mod codex_app_server_hooks;
mod codex_app_server_policy;
mod codex_app_server_strategies;
mod codex_hooks;
mod codex_hooks_adapter;
mod codex_hooks_diag;
mod event_schema;
mod git_root;
mod hook_checks;
mod hook_checks_bash;
mod hook_checks_common;
mod hook_checks_history;
mod hook_checks_scan;
mod hook_checks_write;
mod hook_checks_write_scan;
mod hook_orchestrator;
mod hook_orchestrator_context;
mod hook_orchestrator_pre_bash;
mod hook_orchestrator_pre_edit;
mod hook_orchestrator_stop;
mod hook_output;
mod hook_status;
mod json_field;
mod log_append;
mod log_query;
mod log_scope;
mod observe;
mod pkg_rewrite;
mod project_config;
mod project_config_scoped_suppression;
mod runtime_config;
mod runtime_policy;
mod session_metrics;
mod setup_codex_config;
mod setup_codex_hooks;
mod setup_codex_hooks_health;
mod setup_install_state;
mod setup_manifest;
mod setup_markdown;
mod setup_support;
mod time_utils;
mod wrapper_env;

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
        name: "version",
        usage: "  — print the vibeguard-runtime package version",
        handler: version,
    },
    Command {
        name: "json-field",
        usage: "<field_path>  — extract one field from stdin JSON",
        handler: json_field::run_field,
    },
    Command {
        name: "json-bool-field",
        usage: "<field_path>  — extract one boolean field from stdin JSON",
        handler: json_field::run_bool_field,
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
        name: "reason-count",
        usage: "<session> <hook> <reason>  — count exact hook/reason events",
        handler: log_query::reason_count,
    },
    Command {
        name: "post-edit-history",
        usage: "<session> <file> [agent]  — summarize post-edit history signals",
        handler: log_query::post_edit_history,
    },
    Command {
        name: "post-edit-w15",
        usage: "<session> <file>  — emit W-15 same-file edit trail metadata",
        handler: log_query::post_edit_w15,
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
        name: "append-jsonl-mirror",
        usage: "<primary-log-file> <mirror-log-file>  — append one stdin JSONL line to two JSONL files with runtime locking",
        handler: log_append::run_mirror,
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
        name: "hook",
        usage: "<pre-write|pre-bash|pre-edit|post-write|post-edit|stop|learn>  — run a single-process hook orchestrator scaffold",
        handler: hook_orchestrator::run,
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
        name: "active-constraints",
        usage: "--root DIR --home DIR [--task-path PATH] [--skill NAME] [--json|--hook-fields]  — count effective active constraints",
        handler: active_constraints::run,
    },
    Command {
        name: "hook-status",
        usage: "[--mode minimal|focused|full] [--json] [--scope project|global] [--project PATH_OR_HASH] [--log-file PATH] [--diag-file PATH]  — summarize hook pass/skip/warn/timeout status without adding model context",
        handler: hook_status::run,
    },
    Command {
        name: "hook-context",
        usage: "<event-name>  — emit hookSpecificOutput.additionalContext from stdin",
        handler: hook_output::context,
    },
    Command {
        name: "stop-reason",
        usage: "  — emit Stop hook stopReason from stdin",
        handler: hook_output::stop_reason,
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
        name: "codex-status-info",
        usage: "  — extract Codex event, matcher, and status detail from stdin",
        handler: codex_hooks::status_info,
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
        name: "codex-visible-failure",
        usage: "<event-name>  — emit a Codex visible failure payload from stdin reason",
        handler: codex_hooks_diag::visible_failure,
    },
    Command {
        name: "codex-diag",
        usage: "<diag-file> <hook-name> <event-name> <reason> <detail> <cwd>  — append a Codex wrapper diagnostic JSONL event",
        handler: codex_hooks_diag::diag,
    },
    Command {
        name: "codex-hook-status",
        usage: "<diag-file> <hook-name> <event-name> <matcher> <status> <reason> <detail> <timeout-ms>  — append a Codex hook status JSONL event",
        handler: codex_hooks_diag::hook_status,
    },
    Command {
        name: "codex-hook-start",
        usage: "<diag-file> <hook-name> <timeout-ms>  — parse Codex hook input, append running status, and emit event/matcher/detail",
        handler: codex_hooks_diag::hook_start,
    },
    Command {
        name: "codex-hook-status-from-output",
        usage: "<diag-file> <hook-name> <event-name> <matcher> <detail> <timeout-ms>  — classify wrapped hook output and append Codex status JSONL",
        handler: codex_hooks_diag::hook_status_from_output,
    },
    Command {
        name: "codex-finalize-output",
        usage: "<diag-file> <hook-name> <event-name> <matcher> <detail> <timeout-ms>  — append final status and adapt wrapped hook output",
        handler: codex_hooks_diag::finalize_output,
    },
    Command {
        name: "codex-adapt-pretool",
        usage: "  — adapt wrapped hook output to Codex PreToolUse JSON",
        handler: codex_hooks_adapter::adapt_pretool,
    },
    Command {
        name: "codex-adapt-posttool",
        usage: "  — adapt wrapped hook output to Codex PostToolUse JSON",
        handler: codex_hooks_adapter::adapt_posttool,
    },
    Command {
        name: "codex-adapt-permission-request",
        usage: "  — adapt wrapped hook output to Codex PermissionRequest JSON",
        handler: codex_hooks_adapter::adapt_permission_request,
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
        name: "runtime-policy-supports",
        usage: "  — verify this runtime supports policy helper commands",
        handler: runtime_policy::runtime_policy_supports,
    },
    Command {
        name: "runtime-policy-downgrade-output",
        usage: "[--warn-mode] [--cwd <path>] [--payload <path-or-json>] [<hook-name>]  — downgrade stdin hook JSON for warn-mode or scoped suppressions",
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
        name: "wrapper-env",
        usage: "[cli]  — precompute hook wrapper log and session environment",
        handler: wrapper_env::run,
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
        name: "u16-limit",
        usage: "<file-path> <base-limit>  — resolve U-16 project exemption limit",
        handler: hook_checks::u16_limit,
    },
    Command {
        name: "test-path-filter",
        usage: "<--test|--prod>  — filter newline-separated paths by canonical test-path classification",
        handler: hook_checks::test_path_filter,
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
    Command {
        name: "setup-manifest-skill-links",
        usage: "<repo-dir> <target>  — list manifest skill links",
        handler: setup_manifest::skill_links,
    },
    Command {
        name: "setup-manifest-rule-links",
        usage: "<repo-dir> [languages]  — list manifest rule links",
        handler: setup_manifest::rule_links,
    },
    Command {
        name: "setup-manifest-rule-labels",
        usage: "<repo-dir> [languages]  — list manifest rule labels",
        handler: setup_manifest::rule_labels,
    },
    Command {
        name: "setup-md-diff-inject",
        usage: "<target-file> <rules-file> <repo-dir> <rule-count>  — render managed Markdown diff",
        handler: setup_markdown::diff_inject,
    },
    Command {
        name: "setup-md-inject",
        usage: "<target-file> <rules-file> <repo-dir> <rule-count>  — inject managed Markdown block",
        handler: setup_markdown::inject,
    },
    Command {
        name: "setup-md-remove",
        usage: "<target-file>  — remove managed Markdown block",
        handler: setup_markdown::remove,
    },
    Command {
        name: "setup-settings-check",
        usage: "<repo-dir> <settings-file> <pre-hooks|post-hooks|full-hooks|profile-hooks:<profile>>  — check Claude settings",
        handler: setup_markdown::settings_check,
    },
    Command {
        name: "setup-settings-check-supports-profile-hooks",
        usage: "— capability probe for profile-hooks setup-settings-check target",
        handler: setup_markdown::settings_check_supports_profile_hooks,
    },
    Command {
        name: "setup-settings-upsert",
        usage: "<repo-dir> <settings-file> <profile> [--dry-run] [--force-overwrite]  — upsert Claude settings",
        handler: setup_markdown::settings_upsert,
    },
    Command {
        name: "setup-settings-remove",
        usage: "<repo-dir> <settings-file>  — remove VibeGuard Claude settings",
        handler: setup_markdown::settings_remove,
    },
    Command {
        name: "setup-settings-check-stale",
        usage: "<settings-file>  — detect stale Claude hook commands",
        handler: setup_markdown::settings_check_stale,
    },
    Command {
        name: "setup-state-init",
        usage: "<state-file> <profile> <languages>  — initialize install state",
        handler: setup_install_state::init,
    },
    Command {
        name: "setup-state-record-file",
        usage: "<state-file> <dest> <source> <type>  — record install-state file",
        handler: setup_install_state::record_file,
    },
    Command {
        name: "setup-state-record-project-hook",
        usage: "<state-file> <repo-dir> <hook-path> <hook-name>  — record project git hook",
        handler: setup_install_state::record_project_hook,
    },
    Command {
        name: "setup-state-check-drift",
        usage: "<state-file>  — check install-state drift",
        handler: setup_install_state::check_drift,
    },
    Command {
        name: "setup-state-list",
        usage: "<state-file>  — list install-state files",
        handler: setup_install_state::list,
    },
    Command {
        name: "setup-state-list-symlinks-under",
        usage: "<state-file> <dest-dir>  — list tracked symlinks under a directory",
        handler: setup_install_state::list_tracked_symlinks_under,
    },
    Command {
        name: "setup-state-list-project-hooks",
        usage: "<state-file>  — list tracked project git hooks",
        handler: setup_install_state::list_project_hooks,
    },
    Command {
        name: "setup-codex-config-enable-hooks",
        usage: "<config-file>  — enable Codex hooks feature",
        handler: setup_codex_config::enable_hooks,
    },
    Command {
        name: "setup-codex-config-check-hooks",
        usage: "<config-file>  — check Codex hooks feature",
        handler: setup_codex_config::check_hooks,
    },
    Command {
        name: "setup-codex-hooks-upsert",
        usage: "<repo-dir> <hooks-file> <wrapper>  — upsert Codex hooks",
        handler: setup_codex_hooks::codex_hooks_upsert,
    },
    Command {
        name: "setup-codex-hooks-remove",
        usage: "<repo-dir> <hooks-file>  — remove VibeGuard Codex hooks",
        handler: setup_codex_hooks::codex_hooks_remove,
    },
    Command {
        name: "setup-codex-hooks-check",
        usage: "<repo-dir> <hooks-file> <wrapper>  — check Codex hooks",
        handler: setup_codex_hooks::codex_hooks_check,
    },
    Command {
        name: "setup-codex-hooks-count",
        usage: "<hooks-file>  — count Codex hook entries",
        handler: setup_codex_hooks::codex_hooks_count,
    },
    Command {
        name: "setup-codex-hooks-check-stale",
        usage: "[repo-dir] <hooks-file>  — detect stale Codex hook commands",
        handler: setup_codex_hooks::codex_hooks_check_stale,
    },
    Command {
        name: "setup-codex-hooks-prune-stale-unmanaged",
        usage: "<repo-dir> <hooks-file> [event...]  — remove missing-target unmanaged Codex hooks for selected events",
        handler: setup_codex_hooks::codex_hooks_prune_stale_unmanaged,
    },
    Command {
        name: "setup-codex-hooks-check-timeouts",
        usage: "<repo-dir> <hooks-file>  — detect Codex hooks without timeout",
        handler: setup_codex_hooks::codex_hooks_check_timeouts,
    },
];

fn version(args: &[String]) -> HandlerResult {
    if !args.is_empty() {
        return Err("Usage: vibeguard-runtime version".into());
    }
    println!("{}", env!("CARGO_PKG_VERSION"));
    Ok(())
}

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
