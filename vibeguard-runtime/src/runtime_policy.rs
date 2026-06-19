use crate::HandlerResult;
use crate::codex_app_server_policy::{HookPolicyDecision, evaluate_hook_policy};
use crate::project_config::{load_project_config, project_config_path, project_config_root};
use crate::project_config_scoped_suppression::{
    ScopedSuppression, scoped_suppression_matches_output,
};
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
    Ok(())
}

pub fn runtime_policy_check(args: &[String]) -> HandlerResult {
    let parsed = parse_runtime_policy_check_args(args)?;

    let user_config = std::env::var("VIBEGUARD_USER_CONFIG_FILE").unwrap_or_default();
    if let Err(err) = validate_runtime_config_file(&user_config) {
        let payload = runtime_policy_error_payload(
            &parsed.hook_name,
            parsed.cwd.as_deref(),
            None,
            &err.message,
        );
        eprintln!("{}", err.message);
        exit_with_policy_payload(payload, err.exit_code);
    }

    let env_overrides = HashMap::new();
    let config_path = project_config_path(parsed.cwd.as_deref(), &env_overrides);
    let decision = evaluate_hook_policy(&parsed.hook_name, parsed.cwd.as_deref(), &env_overrides);
    let payload = runtime_policy_payload(
        &parsed.hook_name,
        parsed.cwd.as_deref(),
        config_path.as_deref(),
        &decision,
    );
    match decision {
        HookPolicyDecision::Run { .. } => {
            exit_with_policy_payload(payload, ALLOW);
        }
        HookPolicyDecision::Skip(_) => {
            exit_with_policy_payload(payload, SKIP);
        }
        HookPolicyDecision::Error(reason) => {
            eprintln!("{reason}");
            exit_with_policy_payload(payload, policy_error_exit_code(&reason));
        }
    }
}

pub fn runtime_policy_downgrade_output(args: &[String]) -> HandlerResult {
    let parsed = parse_runtime_policy_downgrade_args(args)?;
    let payload = runtime_policy_payload_arg(parsed.payload.as_deref())?;

    let raw = read_stdin()?;
    let Ok(mut value) = serde_json::from_str::<Value>(&raw) else {
        print_raw_with_newline(&raw)?;
        return Ok(());
    };

    let Some(object) = value.as_object_mut() else {
        println!("{}", serde_json::to_string(&value)?);
        return Ok(());
    };

    let output_snapshot = Value::Object(object.clone());
    if let Some(suppression) = matching_scoped_suppression(
        parsed.cwd.as_deref(),
        parsed.hook_name.as_deref(),
        &output_snapshot,
        payload.as_ref(),
    ) {
        apply_scoped_suppression_output(object, &suppression);
    } else if parsed.warn_mode {
        downgrade_object_to_warn(object);
    }

    println!("{}", serde_json::to_string_pretty(&value)?);
    Ok(())
}

fn downgrade_object_to_warn(object: &mut serde_json::Map<String, Value>) {
    let mut changed = false;
    if matches!(
        object.get("decision").and_then(Value::as_str),
        Some("block" | "gate" | "escalate")
    ) {
        object.insert("decision".to_string(), json!("warn"));
        changed = true;
    }

    if changed {
        prefix_reason(object, "VIBEGUARD warn-mode advisory");
    }

    remove_codex_denials(object, "VIBEGUARD warn-mode advisory", true);
}

pub(crate) fn apply_scoped_suppression_value(value: &mut Value, suppression: &ScopedSuppression) {
    let Some(object) = value.as_object_mut() else {
        return;
    };
    apply_scoped_suppression_output(object, suppression);
}

fn apply_scoped_suppression_output(
    object: &mut serde_json::Map<String, Value>,
    suppression: &ScopedSuppression,
) {
    let prefix = format!("VIBEGUARD scoped suppression: {}", suppression.reason);
    if suppression.action == "suppress" {
        object.insert("decision".to_string(), json!("pass"));
        object.insert("reason".to_string(), json!(prefix));
        clear_native_advisory_output(object);
        remove_codex_denials(object, "VIBEGUARD scoped suppression", false);
    } else {
        object.insert("decision".to_string(), json!("warn"));
        prefix_reason(object, &prefix);
        remove_codex_denials(object, &prefix, true);
    }
}

fn clear_native_advisory_output(object: &mut serde_json::Map<String, Value>) {
    object.remove("systemMessage");
    if let Some(hook_specific) = object
        .get_mut("hookSpecificOutput")
        .and_then(Value::as_object_mut)
    {
        hook_specific.remove("additionalContext");
        hook_specific.remove("permissionDecisionReason");
        if hook_specific.keys().all(|key| key == "hookEventName") {
            object.remove("hookSpecificOutput");
        }
    }
}

fn prefix_reason(object: &mut serde_json::Map<String, Value>, prefix: &str) {
    if let Some(reason) = object.get("reason").and_then(Value::as_str) {
        if !reason.is_empty() {
            object.insert("reason".to_string(), json!(format!("{prefix}: {reason}")));
        }
    }
}

fn remove_codex_denials(
    object: &mut serde_json::Map<String, Value>,
    prefix: &str,
    emit_advisory: bool,
) {
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
                if emit_advisory
                    && !message.is_empty()
                    && !has_system_message
                    && advisory_message.is_none()
                {
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
                if emit_advisory
                    && !message.is_empty()
                    && !has_system_message
                    && advisory_message.is_none()
                {
                    advisory_message = Some(message);
                }
            }
        }
    }
    if let Some(message) = advisory_message {
        object.insert(
            "systemMessage".to_string(),
            json!(format!("{prefix}: {message}")),
        );
    }
}

fn matching_scoped_suppression(
    cwd: Option<&str>,
    hook_name: Option<&str>,
    output: &Value,
    payload: Option<&Value>,
) -> Option<ScopedSuppression> {
    let hook_name = hook_name?;
    let config_path = project_config_path(cwd, &HashMap::new())?;
    let project_root = project_config_root(&config_path);
    let config = load_project_config(&config_path).ok()?;
    config.scoped_suppressions.into_iter().find(|suppression| {
        scoped_suppression_matches_output(
            suppression,
            hook_name,
            output,
            payload,
            project_root.as_deref(),
        )
    })
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

struct RuntimePolicyCheckArgs {
    hook_name: String,
    cwd: Option<String>,
}

struct RuntimePolicyDowngradeArgs {
    warn_mode: bool,
    hook_name: Option<String>,
    cwd: Option<String>,
    payload: Option<String>,
}

fn parse_runtime_policy_check_args(args: &[String]) -> Result<RuntimePolicyCheckArgs, String> {
    let mut cwd: Option<String> = None;
    let mut hook_name: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--cwd" | "--project-root" => {
                i += 1;
                let Some(value) = args.get(i) else {
                    return Err(runtime_policy_check_usage());
                };
                if value.is_empty() || cwd.replace(value.clone()).is_some() {
                    return Err(runtime_policy_check_usage());
                }
            }
            "--" => {
                i += 1;
                if i >= args.len() || hook_name.is_some() || i + 1 != args.len() {
                    return Err(runtime_policy_check_usage());
                }
                hook_name = Some(args[i].clone());
            }
            arg if arg.starts_with("--") => return Err(runtime_policy_check_usage()),
            value => {
                if hook_name.replace(value.to_string()).is_some() {
                    return Err(runtime_policy_check_usage());
                }
            }
        }
        i += 1;
    }

    let Some(hook_name) = hook_name else {
        return Err(runtime_policy_check_usage());
    };
    Ok(RuntimePolicyCheckArgs { hook_name, cwd })
}

fn runtime_policy_check_usage() -> String {
    "Usage: vibeguard-runtime runtime-policy-check [--cwd <path>] <hook-name>".into()
}

fn parse_runtime_policy_downgrade_args(
    args: &[String],
) -> Result<RuntimePolicyDowngradeArgs, String> {
    let mut warn_mode = args.is_empty();
    let mut cwd: Option<String> = None;
    let mut payload: Option<String> = None;
    let mut hook_name: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--warn-mode" => warn_mode = true,
            "--cwd" | "--project-root" => {
                i += 1;
                let Some(value) = args.get(i) else {
                    return Err(runtime_policy_downgrade_usage());
                };
                if value.is_empty() || cwd.replace(value.clone()).is_some() {
                    return Err(runtime_policy_downgrade_usage());
                }
            }
            "--payload" => {
                i += 1;
                let Some(value) = args.get(i) else {
                    return Err(runtime_policy_downgrade_usage());
                };
                if value.is_empty() || payload.replace(value.clone()).is_some() {
                    return Err(runtime_policy_downgrade_usage());
                }
            }
            arg if arg.starts_with("--") => return Err(runtime_policy_downgrade_usage()),
            value => {
                if hook_name.replace(value.to_string()).is_some() {
                    return Err(runtime_policy_downgrade_usage());
                }
            }
        }
        i += 1;
    }

    Ok(RuntimePolicyDowngradeArgs {
        warn_mode,
        hook_name,
        cwd,
        payload,
    })
}

fn runtime_policy_downgrade_usage() -> String {
    "Usage: vibeguard-runtime runtime-policy-downgrade-output [--warn-mode] [--cwd <path>] [--payload <path-or-json>] [<hook-name>]".into()
}

fn runtime_policy_payload_arg(
    payload: Option<&str>,
) -> Result<Option<Value>, Box<dyn std::error::Error>> {
    let Some(payload) = payload else {
        return Ok(None);
    };
    let raw = if Path::new(payload).exists() {
        fs::read_to_string(payload)?
    } else {
        payload.to_string()
    };
    let value = serde_json::from_str::<Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("runtime-policy-downgrade-output payload invalid JSON: {err}"),
        )
    })?;
    Ok(Some(value))
}

fn runtime_policy_payload(
    hook_name: &str,
    cwd: Option<&str>,
    config_path: Option<&Path>,
    decision: &HookPolicyDecision,
) -> Value {
    let config = config_path.and_then(|path| load_project_config(path).ok());
    let output_filter = config
        .as_ref()
        .is_some_and(|config| scoped_output_filter_enabled(&config.scoped_suppressions, hook_name));
    let (enforcement, profile) = config
        .as_ref()
        .map(|config| {
            (
                config
                    .enforcement
                    .clone()
                    .unwrap_or_else(|| "block".to_string()),
                config.profile.clone().unwrap_or_else(|| "core".to_string()),
            )
        })
        .map(|(enforcement, profile)| (json!(enforcement), json!(profile)))
        .unwrap_or_else(|| {
            if config_path.is_some() {
                (Value::Null, Value::Null)
            } else {
                (json!("block"), json!("core"))
            }
        });

    let (decision_text, reason) = match decision {
        HookPolicyDecision::Run { reason, .. } => ("run", reason.clone()),
        HookPolicyDecision::Skip(reason) => ("skip", Some(reason.clone())),
        HookPolicyDecision::Error(reason) => ("error", Some(reason.clone())),
    };

    json!({
        "decision": decision_text,
        "enforcement": enforcement,
        "hook": hook_name,
        "profile": profile,
        "config_path": config_path.map(|path| path.to_string_lossy().to_string()),
        "cwd": cwd,
        "output_filter": output_filter,
        "reason": reason,
    })
}

fn scoped_output_filter_enabled(suppressions: &[ScopedSuppression], hook_name: &str) -> bool {
    suppressions
        .iter()
        .any(|suppression| suppression.hook == canonical_hook_name(hook_name))
}

fn canonical_hook_name(hook_name: &str) -> String {
    let file = Path::new(hook_name)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(hook_name);
    file.strip_suffix(".sh")
        .unwrap_or(file)
        .strip_prefix("vibeguard-")
        .unwrap_or_else(|| file.strip_suffix(".sh").unwrap_or(file))
        .replace('_', "-")
}

fn runtime_policy_error_payload(
    hook_name: &str,
    cwd: Option<&str>,
    config_path: Option<&Path>,
    reason: &str,
) -> Value {
    json!({
        "decision": "error",
        "enforcement": Value::Null,
        "hook": hook_name,
        "profile": Value::Null,
        "config_path": config_path.map(|path| path.to_string_lossy().to_string()),
        "cwd": cwd,
        "reason": reason,
    })
}

fn exit_with_policy_payload(payload: Value, exit_code: i32) -> ! {
    match serde_json::to_string(&payload) {
        Ok(text) => println!("{text}"),
        Err(err) => eprintln!("VibeGuard policy error: could not serialize policy JSON: {err}"),
    }
    process::exit(exit_code);
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
