mod active_constraints;
mod bench;
mod bench_support;
mod circuit_breaker;
mod codex_app_server;
mod codex_hooks;
mod event_schema;
mod gemini_hooks;
mod git_root;
mod guard_scan;
mod hook_checks;
mod hook_input_diag;
mod hook_orchestrator;
mod hook_output;
mod hook_status;
mod installed_profile;
mod json_field;
mod logging;
mod observe;
mod pkg_rewrite;
mod project_config;
mod runtime_config;
mod runtime_policy;
mod session_metrics;
mod setup;
mod time_utils;
mod u16;
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
        name: "bench",
        usage: "[--json]  — run the built-in effectiveness and hook-latency benchmark",
        handler: bench::run,
    },
    Command {
        name: "version",
        usage: "  — print the vibeguard-runtime package version",
        handler: version,
    },
    Command {
        name: "scan",
        usage: "<language> <rule> [--strict] [--baseline <commit>] [target-dir]  — run a canonical language guard",
        handler: guard_scan::run,
    },
    Command {
        name: "json-field",
        usage: "<field_path>  — extract one field from stdin JSON",
        handler: json_field::run_field,
    },
    Command {
        name: "gemini-route-before-tool",
        usage: "  — validate and route a Gemini CLI BeforeTool payload",
        handler: gemini_hooks::route_before_tool,
    },
    Command {
        name: "gemini-adapt-before-tool",
        usage: "  — adapt a canonical guard decision to Gemini CLI BeforeTool output",
        handler: gemini_hooks::adapt_before_tool,
    },
    Command {
        name: "gemini-deny",
        usage: "  — emit a Gemini CLI BeforeTool deny response from stdin reason",
        handler: gemini_hooks::deny,
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
        handler: logging::query::churn_count,
    },
    Command {
        name: "warn-count",
        usage: "<session> <file>  — count warn events for a file",
        handler: logging::query::warn_count,
    },
    Command {
        name: "reason-count",
        usage: "<session> <hook> <reason>  — count exact hook/reason events",
        handler: logging::query::reason_count,
    },
    Command {
        name: "post-edit-history",
        usage: "<session> <file> [agent]  — summarize post-edit history signals",
        handler: logging::query::post_edit_history,
    },
    Command {
        name: "post-edit-w15",
        usage: "<session> <file>  — emit W-15 same-file edit trail metadata",
        handler: logging::query::post_edit_w15,
    },
    Command {
        name: "build-fails",
        usage: "<session> <project>  — count consecutive build failures",
        handler: logging::query::build_fails,
    },
    Command {
        name: "paralysis-count",
        usage: "<session>  — count consecutive read-only tool calls",
        handler: logging::query::paralysis_count,
    },
    Command {
        name: "append-jsonl",
        usage: "<log-file>  — append one stdin JSONL line with runtime locking",
        handler: logging::append::run,
    },
    Command {
        name: "append-jsonl-mirror",
        usage: "<primary-log-file> <mirror-log-file>  — append one stdin JSONL line to two JSONL files with runtime locking",
        handler: logging::append::run_mirror,
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
        handler: hook_checks::bash::pre_bash_check,
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
        usage: "--root DIR --home DIR [--host all|claude|codex] [--task-path PATH] [--skill NAME] [--json|--hook-fields]  — count effective active constraints",
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
        name: "codex-session-id",
        usage: "  — derive a stable logical session id from Codex hook stdin",
        handler: codex_hooks::session_id,
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
        handler: codex_hooks::diag::visible_failure,
    },
    Command {
        name: "codex-diag",
        usage: "<diag-file> <hook-name> <event-name> <reason> <detail> <cwd>  — append a Codex wrapper diagnostic JSONL event",
        handler: codex_hooks::diag::diag,
    },
    Command {
        name: "codex-hook-status",
        usage: "<diag-file> <hook-name> <event-name> <matcher> <status> <reason> <detail> <timeout-ms>  — append a Codex hook status JSONL event",
        handler: codex_hooks::diag::hook_status,
    },
    Command {
        name: "codex-hook-start",
        usage: "<diag-file> <hook-name> <timeout-ms>  — parse Codex hook input, append running status, and emit event/matcher/detail",
        handler: codex_hooks::diag::hook_start,
    },
    Command {
        name: "codex-hook-status-from-output",
        usage: "<diag-file> <hook-name> <event-name> <matcher> <detail> <timeout-ms>  — classify wrapped hook output and append Codex status JSONL",
        handler: codex_hooks::diag::hook_status_from_output,
    },
    Command {
        name: "codex-finalize-output",
        usage: "<diag-file> <hook-name> <event-name> <matcher> <detail> <timeout-ms>  — append final status and adapt wrapped hook output",
        handler: codex_hooks::diag::finalize_output,
    },
    Command {
        name: "codex-adapt-pretool",
        usage: "  — adapt wrapped hook output to Codex PreToolUse JSON",
        handler: codex_hooks::adapter::adapt_pretool,
    },
    Command {
        name: "codex-adapt-posttool",
        usage: "  — adapt wrapped hook output to Codex PostToolUse JSON",
        handler: codex_hooks::adapter::adapt_posttool,
    },
    Command {
        name: "codex-adapt-permission-request",
        usage: "  — adapt wrapped hook output to Codex PermissionRequest JSON",
        handler: codex_hooks::adapter::adapt_permission_request,
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
        name: "config",
        usage: "explain <key-or-env> [--cwd <path>] [--json]  — explain a layered runtime configuration value",
        handler: runtime_config::config,
    },
    Command {
        name: "runtime-config-validate",
        usage: "<config-file>  — validate user runtime configuration",
        handler: runtime_config::runtime_config_validate,
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
        name: "runtime-config-get-list",
        usage: "<env-name> <json-path>  — read a string array from runtime config, one entry per line",
        handler: runtime_config::runtime_config_get_list,
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
        name: "u16-baseline-check",
        usage: "(--staged|--base <ref> [--head <ref>]) [--base-limit <n>]  — enforce baseline-aware U-16 changed-file policy",
        handler: u16::baseline::run_cli,
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
        handler: hook_checks::write::post_write_check,
    },
    Command {
        name: "codex-app-server-wrapper",
        usage: "[--repo-dir DIR] [--strategy vibeguard|noop] [--codex-command CMD]  — run the Rust Codex app-server guard proxy",
        handler: codex_app_server::run,
    },
    Command {
        name: "setup-manifest-skill-links",
        usage: "<repo-dir> <target>  — list manifest skill links",
        handler: setup::manifest::skill_links,
    },
    Command {
        name: "setup-manifest-rule-links",
        usage: "<repo-dir> [languages]  — list manifest rule links",
        handler: setup::manifest::rule_links,
    },
    Command {
        name: "setup-manifest-rule-labels",
        usage: "<repo-dir> [languages]  — list manifest rule labels",
        handler: setup::manifest::rule_labels,
    },
    Command {
        name: "setup-md-diff-inject",
        usage: "<target-file> <rules-file> <repo-dir> <rule-count>  — render managed Markdown diff",
        handler: setup::markdown::diff_inject,
    },
    Command {
        name: "setup-md-inject",
        usage: "<target-file> <rules-file> <repo-dir> <rule-count>  — inject managed Markdown block",
        handler: setup::markdown::inject,
    },
    Command {
        name: "setup-md-remove",
        usage: "<target-file>  — remove managed Markdown block",
        handler: setup::markdown::remove,
    },
    Command {
        name: "setup-md-managed-span",
        usage: "<target-file>  — report managed Markdown block count and line span",
        handler: setup::markdown::managed_span,
    },
    Command {
        name: "setup-settings-check",
        usage: "<repo-dir> <settings-file> <pre-hooks|post-hooks|full-hooks|profile-hooks:<profile>>  — check Claude settings",
        handler: setup::markdown::settings_check,
    },
    Command {
        name: "setup-settings-check-supports-profile-hooks",
        usage: "— capability probe for profile-hooks setup-settings-check target",
        handler: setup::markdown::settings_check_supports_profile_hooks,
    },
    Command {
        name: "setup-settings-upsert",
        usage: "<repo-dir> <settings-file> <profile> [--dry-run] [--force-overwrite]  — upsert Claude settings",
        handler: setup::markdown::settings_upsert,
    },
    Command {
        name: "setup-settings-remove",
        usage: "<repo-dir> <settings-file>  — remove VibeGuard Claude settings",
        handler: setup::markdown::settings_remove,
    },
    Command {
        name: "setup-settings-check-stale",
        usage: "<settings-file>  — detect stale Claude hook commands",
        handler: setup::markdown::settings_check_stale,
    },
    Command {
        name: "setup-state-capabilities",
        usage: "— report the versioned install-state capability contract",
        handler: setup::install_state::capabilities,
    },
    Command {
        name: "setup-state-init",
        usage: "<state-file> <profile> <languages> [generation] [disabled-skills] [carry-state-file] [complete-snapshot] [codex-skills-dir]  — initialize install state or merge a complete outgoing snapshot",
        handler: setup::install_state::init,
    },
    Command {
        name: "setup-state-generation",
        usage: "<state-file>  — report install-state completion and generation",
        handler: setup::install_state::generation,
    },
    Command {
        name: "setup-state-mark-complete",
        usage: "<state-file>  — atomically mark an install-state generation complete",
        handler: setup::install_state::mark_complete,
    },
    Command {
        name: "setup-lock-publish-owner",
        usage: "<lock-dir> <pid> <nonce> [reclaiming]  — durably publish setup lock ownership",
        handler: setup::lock_lifecycle::publish_lock_owner,
    },
    Command {
        name: "setup-lock-acquire",
        usage: "<lock-dir> <pid> <nonce>  — atomically publish a complete setup lock directory",
        handler: setup::lock_lifecycle::acquire,
    },
    Command {
        name: "setup-lock-release",
        usage: "<lock-dir> <pid> <nonce>  — atomically retire an owned setup lock directory",
        handler: setup::lock_lifecycle::release,
    },
    Command {
        name: "setup-state-record-file",
        usage: "<state-file> <dest> <source> <type>  — record install-state file",
        handler: setup::install_state::record_file,
    },
    Command {
        name: "setup-state-record-project-hook",
        usage: "<state-file> <repo-dir> <hook-path> <hook-name>  — record project git hook",
        handler: setup::install_state::record_project_hook,
    },
    Command {
        name: "setup-state-check-drift",
        usage: "<state-file>  — check install-state drift",
        handler: setup::quarantine_inventory::check_drift,
    },
    Command {
        name: "setup-state-list",
        usage: "<state-file>  — list install-state files",
        handler: setup::install_state::list,
    },
    Command {
        name: "setup-state-list-symlinks-under",
        usage: "<state-file> <dest-dir>  — list tracked symlinks under a directory",
        handler: setup::install_state::list_tracked_symlinks_under,
    },
    Command {
        name: "setup-state-list-tracked-under",
        usage: "<state-file> <dest-dir>  — list tracked paths of any type under a directory",
        handler: setup::install_state::list_tracked_under,
    },
    Command {
        name: "setup-state-verify-managed-tree",
        usage: "<state-file> <dest-dir> <source-prefix> [tracked-dest-dir]  — verify exact managed-tree ownership",
        handler: setup::managed_tree_remove::tree_state::verify_managed_tree,
    },
    Command {
        name: "setup-state-quarantine-managed-tree",
        usage: "<state-file> <previous-state-file> <dest-dir> <source-prefix>  — durably quarantine a managed tree without deletion",
        handler: setup::managed_tree_remove::run,
    },
    Command {
        name: "setup-state-release-quarantined-tree",
        usage: "<state-file> <previous-state-file> <dest-dir> <source-prefix>  — release a retained quarantine after canonical re-enable",
        handler: setup::managed_tree_remove::release,
    },
    Command {
        name: "setup-state-validate-managed-tree-transactions",
        usage: "<skills-dir> [state-file previous-state-file]  — validate retained managed-tree transactions before setup or clean mutation",
        handler: setup::managed_tree_remove::validate_transactions,
    },
    Command {
        name: "setup-state-quarantine-count",
        usage: "<state-file> [released-inventory-state-file]  — count active disabled-skill quarantine records",
        handler: setup::quarantine_inventory::count,
    },
    Command {
        name: "setup-state-remove-managed-tree",
        usage: "<state-file> <previous-state-file> <dest-dir> <source-prefix>  — compatibility alias for non-destructive managed-tree quarantine",
        handler: setup::managed_tree_remove::run,
    },
    Command {
        name: "setup-state-list-project-hooks",
        usage: "<state-file>  — list tracked project git hooks",
        handler: setup::install_state::list_project_hooks,
    },
    Command {
        name: "setup-codex-config-enable-hooks",
        usage: "<config-file>  — enable Codex hooks feature",
        handler: setup::codex_config::enable_hooks,
    },
    Command {
        name: "setup-codex-config-check-hooks",
        usage: "<config-file>  — check Codex hooks feature",
        handler: setup::codex_config::check_hooks,
    },
    Command {
        name: "setup-codex-hooks-upsert",
        usage: "<repo-dir> <hooks-file> <wrapper> [profile]  — upsert Codex hooks",
        handler: setup::codex_hooks::codex_hooks_upsert,
    },
    Command {
        name: "setup-codex-hooks-remove",
        usage: "<repo-dir> <hooks-file>  — remove VibeGuard Codex hooks",
        handler: setup::codex_hooks::codex_hooks_remove,
    },
    Command {
        name: "setup-codex-hooks-check",
        usage: "<repo-dir> <hooks-file> <wrapper> [profile]  — check Codex hooks",
        handler: setup::codex_hooks::codex_hooks_check,
    },
    Command {
        name: "setup-codex-hooks-count",
        usage: "<hooks-file>  — count Codex hook entries",
        handler: setup::codex_hooks::codex_hooks_count,
    },
    Command {
        name: "setup-codex-hooks-check-stale",
        usage: "[repo-dir] <hooks-file>  — detect stale Codex hook commands",
        handler: setup::codex_hooks::codex_hooks_check_stale,
    },
    Command {
        name: "setup-codex-hooks-prune-stale-unmanaged",
        usage: "<repo-dir> <hooks-file> [event...]  — remove missing-target unmanaged Codex hooks for selected events",
        handler: setup::codex_hooks::codex_hooks_prune_stale_unmanaged,
    },
    Command {
        name: "setup-codex-hooks-check-timeouts",
        usage: "<repo-dir> <hooks-file>  — detect Codex hooks without timeout",
        handler: setup::codex_hooks::codex_hooks_check_timeouts,
    },
    Command {
        name: "setup-gemini-hooks-upsert",
        usage: "<settings-file> <wrapper> [--dry-run]  — upsert the Gemini CLI adapter",
        handler: setup::gemini_hooks::upsert,
    },
    Command {
        name: "setup-gemini-hooks-remove",
        usage: "<settings-file>  — remove the VibeGuard Gemini CLI adapter",
        handler: setup::gemini_hooks::remove,
    },
    Command {
        name: "setup-gemini-hooks-check",
        usage: "<settings-file> <wrapper>  — check the Gemini CLI adapter",
        handler: setup::gemini_hooks::check,
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
