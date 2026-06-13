use crate::HandlerResult;
use crate::codex_app_server_policy::{HookPolicyReport, evaluate_hook_policy_report};
use crate::runtime_config::validate_runtime_config_file;
use crate::time_utils::{format_unix_secs_utc, now_unix_secs};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;
use std::process;

const ALLOW: i32 = 0;
const SKIP: i32 = 10;
const POLICY_ERROR: i32 = 20;
const CONFIG_PARSE_ERROR: i32 = 30;

pub fn runtime_policy_supports(args: &[String]) -> HandlerResult {
    if !args.is_empty() {
        return Err("Usage: vibeguard-runtime runtime-policy-supports".into());
    }
    println!("runtime-policy-json-v1");
    Ok(())
}

pub fn runtime_policy_check(args: &[String]) -> HandlerResult {
    let args = parse_runtime_policy_check_args(args)?;

    let user_config = std::env::var("VIBEGUARD_USER_CONFIG_FILE").unwrap_or_default();
    if let Err(err) = validate_runtime_config_file(&user_config) {
        let report = HookPolicyReport {
            decision: "error".to_string(),
            enforcement: "block".to_string(),
            hook: args.hook_name.clone(),
            profile: "core".to_string(),
            config_path: None,
            reason: Some(err.message),
            warn_mode: false,
        };
        print_policy_report(&report, true, args.output_format)?;
        process::exit(err.exit_code);
    }

    let decision =
        evaluate_hook_policy_report(&args.hook_name, args.cwd.as_deref(), &HashMap::new());
    match decision {
        report if report.decision == "run" => {
            print_policy_report(&report, false, args.output_format)?;
            process::exit(ALLOW);
        }
        report if report.decision == "skip" => {
            print_policy_report(&report, false, args.output_format)?;
            process::exit(SKIP);
        }
        report => {
            let reason = report.reason.as_deref().unwrap_or("");
            print_policy_report(&report, true, args.output_format)?;
            process::exit(policy_error_exit_code(reason));
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PolicyOutputFormat {
    Json,
    Text,
}

struct RuntimePolicyCheckArgs {
    hook_name: String,
    cwd: Option<String>,
    output_format: PolicyOutputFormat,
}

fn parse_runtime_policy_check_args(args: &[String]) -> Result<RuntimePolicyCheckArgs, String> {
    let mut cwd = None;
    let mut output_format = PolicyOutputFormat::Json;
    let mut hook_name = None;
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--cwd" | "--project-root" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(runtime_policy_check_usage());
                };
                cwd = Some(value.clone());
                index += 2;
            }
            "--format" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(runtime_policy_check_usage());
                };
                output_format = match value.as_str() {
                    "json" => PolicyOutputFormat::Json,
                    "text" => PolicyOutputFormat::Text,
                    _ => return Err(runtime_policy_check_usage()),
                };
                index += 2;
            }
            value if value.starts_with('-') => return Err(runtime_policy_check_usage()),
            value => {
                if hook_name.replace(value.to_string()).is_some() {
                    return Err(runtime_policy_check_usage());
                }
                index += 1;
            }
        }
    }

    let Some(hook_name) = hook_name else {
        return Err(runtime_policy_check_usage());
    };

    Ok(RuntimePolicyCheckArgs {
        hook_name,
        cwd,
        output_format,
    })
}

fn runtime_policy_check_usage() -> String {
    "Usage: vibeguard-runtime runtime-policy-check [--cwd <path>|--project-root <path>] [--format json|text] <hook-name>".into()
}

fn print_policy_report(
    report: &HookPolicyReport,
    stderr: bool,
    output_format: PolicyOutputFormat,
) -> HandlerResult {
    let text = match output_format {
        PolicyOutputFormat::Json => serde_json::to_string(&json!({
            "decision": report.decision,
            "enforcement": report.enforcement,
            "hook": report.hook,
            "profile": report.profile,
            "config_path": report.config_path,
            "reason": report.reason,
            "warn_mode": report.warn_mode,
        }))?,
        PolicyOutputFormat::Text => report.reason.clone().unwrap_or_default(),
    };
    if stderr {
        eprintln!("{text}");
    } else {
        println!("{text}");
    }
    Ok(())
}

pub fn runtime_policy_downgrade_output(args: &[String]) -> HandlerResult {
    if !args.is_empty() {
        return Err("Usage: vibeguard-runtime runtime-policy-downgrade-output".into());
    }

    let raw = read_stdin()?;
    let Ok(mut value) = serde_json::from_str::<Value>(&raw) else {
        print_raw_with_newline(&raw)?;
        return Ok(());
    };

    let Some(object) = value.as_object_mut() else {
        println!("{}", serde_json::to_string(&value)?);
        return Ok(());
    };

    let mut changed = false;
    if matches!(
        object.get("decision").and_then(Value::as_str),
        Some("block" | "gate" | "escalate")
    ) {
        object.insert("decision".to_string(), json!("warn"));
        changed = true;
    }

    if changed {
        if let Some(reason) = object.get("reason").and_then(Value::as_str) {
            if !reason.is_empty() {
                object.insert(
                    "reason".to_string(),
                    json!(format!("VIBEGUARD warn-mode advisory: {reason}")),
                );
            }
        }
    }

    let has_system_message = object.contains_key("systemMessage");
    let mut advisory_message: Option<String> = None;
    if let Some(hook_specific) = object
        .get_mut("hookSpecificOutput")
        .and_then(Value::as_object_mut)
    {
        if hook_specific
            .get("permissionDecision")
            .and_then(Value::as_str)
            == Some("deny")
        {
            let message = hook_specific
                .remove("permissionDecisionReason")
                .and_then(|value| value.as_str().map(str::to_string));
            hook_specific.remove("permissionDecision");
            if let Some(message) = message {
                if !message.is_empty() && !has_system_message && advisory_message.is_none() {
                    advisory_message = Some(message);
                }
            }
        }

        if hook_specific
            .get("decision")
            .and_then(Value::as_object)
            .and_then(|decision| decision.get("behavior"))
            .and_then(Value::as_str)
            == Some("deny")
        {
            let message = hook_specific
                .get("decision")
                .and_then(Value::as_object)
                .and_then(|decision| decision.get("message"))
                .and_then(Value::as_str)
                .map(str::to_string);
            hook_specific.remove("decision");
            if let Some(message) = message {
                if !message.is_empty() && !has_system_message && advisory_message.is_none() {
                    advisory_message = Some(message);
                }
            }
        }
    }
    if let Some(message) = advisory_message {
        object.insert(
            "systemMessage".to_string(),
            json!(format!("VIBEGUARD warn-mode advisory: {message}")),
        );
    }

    println!("{}", serde_json::to_string_pretty(&value)?);
    Ok(())
}

pub fn runtime_policy_codex_error(args: &[String]) -> HandlerResult {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime runtime-policy-codex-error <event-name>".into());
    }

    let reason = read_stdin()?;
    let payload = codex_error_payload(&args[0], &reason);
    println!("{}", serde_json::to_string_pretty(&payload)?);
    Ok(())
}

pub fn runtime_policy_diag(args: &[String]) -> HandlerResult {
    if args.len() != 5 {
        return Err("Usage: vibeguard-runtime runtime-policy-diag <diag-file> <hook-name> <event-name> <kind> <wrapper>".into());
    }

    let diag_file = Path::new(&args[0]);
    if let Some(parent) = diag_file.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent)?;
        }
    }

    let reason = read_stdin()?;
    let payload = json!({
        "ts": format_unix_secs_utc(now_unix_secs()),
        "wrapper": args[4],
        "hook": args[1],
        "event": args[2],
        "kind": args[3],
        "reason": reason,
    });
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(diag_file)?;
    writeln!(file, "{}", serde_json::to_string(&payload)?)?;
    Ok(())
}

fn policy_error_exit_code(reason: &str) -> i32 {
    if reason.contains("project config invalid JSON")
        || reason.contains("project config invalid UTF-8")
    {
        CONFIG_PARSE_ERROR
    } else {
        POLICY_ERROR
    }
}

fn read_stdin() -> io::Result<String> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    Ok(input)
}

fn print_raw_with_newline(raw: &str) -> io::Result<()> {
    print!("{raw}");
    if !raw.is_empty() && !raw.ends_with('\n') {
        println!();
    }
    Ok(())
}

fn codex_error_payload(event: &str, reason: &str) -> Value {
    match event {
        "PreToolUse" => json!({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        }),
        "PermissionRequest" => json!({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {
                    "behavior": "deny",
                    "message": reason,
                },
            }
        }),
        "PostToolUse" => json!({
            "decision": "block",
            "reason": reason,
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": reason,
            },
        }),
        "Stop" => json!({ "stopReason": reason }),
        _ => json!({ "systemMessage": reason }),
    }
}

#[cfg(test)]
mod tests {
    use super::policy_error_exit_code;

    #[test]
    fn runtime_policy_project_json_parse_errors_keep_config_parse_exit_code() {
        assert_eq!(
            policy_error_exit_code(
                "VibeGuard project config invalid JSON: /tmp/.vibeguard.json: EOF"
            ),
            30
        );
    }

    #[test]
    fn runtime_policy_project_utf8_parse_errors_keep_config_parse_exit_code() {
        assert_eq!(
            policy_error_exit_code("VibeGuard project config invalid UTF-8: /tmp/.vibeguard.json"),
            30
        );
    }

    #[test]
    fn runtime_policy_schema_errors_keep_policy_error_exit_code() {
        assert_eq!(
            policy_error_exit_code(
                "VibeGuard project config invalid: /tmp/.vibeguard.json disabled_hooks contains unsupported hook missing-hook"
            ),
            20
        );
    }
}
