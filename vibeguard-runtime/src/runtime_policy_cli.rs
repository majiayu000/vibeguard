use crate::codex_app_server_policy::{
    HookPolicyDecision, evaluate_hook_policy, validate_project_config_path,
};
use crate::time_utils::{format_unix_secs_utc, now_unix_secs};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::path::Path;

const SKIP: i32 = 10;
const POLICY_ERROR: i32 = 20;
const CONFIG_PARSE_ERROR: i32 = 30;

pub fn check(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let mut hook_name: Option<String> = None;
    let mut cwd: Option<String> = None;
    let mut user_config: Option<String> = std::env::var("VIBEGUARD_USER_CONFIG_FILE").ok();
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--cwd" => {
                index += 1;
                cwd = args.get(index).cloned();
            }
            "--user-config" => {
                index += 1;
                user_config = args.get(index).cloned();
            }
            value if hook_name.is_none() => hook_name = Some(value.to_string()),
            other => return Err(format!("unexpected argument: {other}").into()),
        }
        index += 1;
    }

    let hook_name = hook_name.ok_or("runtime-policy-check requires a hook name")?;
    if let Some(path) = user_config.as_deref().filter(|path| !path.is_empty()) {
        if let Err(reason) = validate_runtime_config(path) {
            eprintln!("{reason}");
            std::process::exit(CONFIG_PARSE_ERROR);
        }
    }

    match evaluate_hook_policy(&hook_name, cwd.as_deref(), &HashMap::new()) {
        HookPolicyDecision::Run {
            reason: Some(reason),
            ..
        } => {
            println!("{reason}");
            Ok(())
        }
        HookPolicyDecision::Run { .. } => Ok(()),
        HookPolicyDecision::Skip(reason) => {
            println!("{reason}");
            std::process::exit(SKIP);
        }
        HookPolicyDecision::Error(reason) => {
            eprintln!("{reason}");
            if is_config_parse_error(&reason) {
                std::process::exit(CONFIG_PARSE_ERROR);
            }
            std::process::exit(POLICY_ERROR);
        }
    }
}

pub fn downgrade_output(_args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let mut raw = String::new();
    std::io::stdin().read_to_string(&mut raw)?;
    let Ok(mut data) = serde_json::from_str::<Value>(&raw) else {
        print_with_newline(&raw);
        return Ok(());
    };
    let Some(object) = data.as_object_mut() else {
        println!("{}", serde_json::to_string(&data)?);
        return Ok(());
    };

    let mut changed = false;
    if object
        .get("decision")
        .and_then(Value::as_str)
        .is_some_and(|decision| matches!(decision, "block" | "gate" | "escalate"))
    {
        object.insert("decision".into(), Value::String("warn".into()));
        changed = true;
    }
    if changed {
        if let Some(reason) = object.get("reason").and_then(Value::as_str) {
            if !reason.is_empty() {
                object.insert(
                    "reason".into(),
                    Value::String(format!("VIBEGUARD warn-mode advisory: {reason}")),
                );
            }
        }
    }

    let had_system_message = object.get("systemMessage").is_some();
    let mut system_message: Option<String> = None;
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
            if !had_system_message {
                system_message = message
                    .filter(|message| !message.is_empty())
                    .map(|message| format!("VIBEGUARD warn-mode advisory: {message}"));
            }
        }

        let deny_message = hook_specific
            .get("decision")
            .and_then(Value::as_object)
            .filter(|decision| {
                decision
                    .get("behavior")
                    .and_then(Value::as_str)
                    .is_some_and(|behavior| behavior == "deny")
            })
            .and_then(|decision| decision.get("message"))
            .and_then(Value::as_str)
            .map(str::to_string);
        if deny_message.is_some() {
            hook_specific.remove("decision");
            if !had_system_message && system_message.is_none() {
                system_message = deny_message
                    .filter(|message| !message.is_empty())
                    .map(|message| format!("VIBEGUARD warn-mode advisory: {message}"));
            }
        }
    }
    if let Some(message) = system_message {
        object.insert("systemMessage".into(), Value::String(message));
    }

    println!("{}", serde_json::to_string_pretty(&data)?);
    Ok(())
}

pub fn codex_error(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let event = args
        .first()
        .ok_or("runtime-policy-codex-error requires an event")?;
    let mut reason = String::new();
    std::io::stdin().read_to_string(&mut reason)?;
    let reason = reason.trim_end_matches('\n');
    let payload = match event.as_str() {
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
                "decision": {"behavior": "deny", "message": reason},
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
        "Stop" => json!({"stopReason": reason}),
        _ => json!({"systemMessage": reason}),
    };
    println!("{}", serde_json::to_string_pretty(&payload)?);
    Ok(())
}

pub fn diag(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    if args.len() != 5 {
        return Err(
            "runtime-policy-diag requires <diag-file> <hook> <event> <kind> <wrapper>".into(),
        );
    }
    let mut reason = String::new();
    std::io::stdin().read_to_string(&mut reason)?;
    let diag_file = Path::new(&args[0]);
    if let Some(parent) = diag_file.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let entry = json!({
        "ts": format_unix_secs_utc(now_unix_secs()),
        "wrapper": args[4],
        "hook": args[1],
        "event": args[2],
        "kind": args[3],
        "reason": reason.trim_end_matches('\n'),
    });
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(diag_file)?;
    writeln!(file, "{}", serde_json::to_string(&entry)?)?;
    Ok(())
}

pub fn project_config_validate(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let path = args
        .first()
        .ok_or("project-config-validate requires <config-file>")?;
    match validate_project_config_path(Path::new(path)) {
        Ok(()) => Ok(()),
        Err(reason) => {
            eprintln!("{reason}");
            if is_config_parse_error(&reason) {
                std::process::exit(CONFIG_PARSE_ERROR);
            }
            std::process::exit(POLICY_ERROR);
        }
    }
}

pub fn project_config_value(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    if args.len() != 3 {
        return Err("project-config-value requires <config-file> <json-path> <default>".into());
    }
    let path = Path::new(&args[0]);
    let default_value = &args[2];
    if !path.is_file() {
        println!("{default_value}");
        return Ok(());
    }
    if let Err(reason) = validate_project_config_path(path) {
        eprintln!("{reason}");
        if is_config_parse_error(&reason) {
            std::process::exit(CONFIG_PARSE_ERROR);
        }
        std::process::exit(POLICY_ERROR);
    }
    let text = std::fs::read_to_string(path)?;
    let mut value = serde_json::from_str::<Value>(&text)?;
    for key in args[1].split('.') {
        let Some(next) = value.as_object().and_then(|object| object.get(key)) else {
            println!("{default_value}");
            return Ok(());
        };
        value = next.clone();
    }
    match value {
        Value::Bool(_) | Value::Null => println!("{default_value}"),
        Value::String(text) => println!("{text}"),
        Value::Number(number) => println!("{number}"),
        other => println!("{}", serde_json::to_string(&other)?),
    }
    Ok(())
}

fn validate_runtime_config(path: &str) -> Result<(), String> {
    let path = Path::new(path);
    if !path.is_file() {
        return Ok(());
    }
    let text = std::fs::read_to_string(path).map_err(|err| {
        format!(
            "VibeGuard runtime config cannot be read: {}: {err}",
            path.display()
        )
    })?;
    serde_json::from_str::<Value>(&text)
        .map(|_| ())
        .map_err(|err| {
            format!(
                "VibeGuard runtime config invalid JSON: {}: {err}",
                path.display()
            )
        })
}

fn is_config_parse_error(reason: &str) -> bool {
    reason.contains("invalid JSON")
        || reason.contains("invalid UTF-8")
        || reason.contains("cannot be read")
}

fn print_with_newline(raw: &str) {
    print!("{raw}");
    if !raw.is_empty() && !raw.ends_with('\n') {
        println!();
    }
}
