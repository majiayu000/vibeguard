use crate::{Result, hook_checks, logging, print_json, read_stdin};
use serde_json::{Value, json};
use std::path::Path;

pub fn run(args: &[String]) -> Result<u8> {
    let host = args
        .first()
        .map(String::as_str)
        .ok_or("hook needs claude or codex")?;
    if !matches!(host, "claude" | "codex") {
        return Err("hook host must be claude or codex".into());
    }
    let state_dir = match &args[1..] {
        [] => None,
        [flag, path] if flag == "--state-dir" => Some(Path::new(path)),
        _ => return Err("usage: hook <claude|codex> [--state-dir PATH]".into()),
    };
    let input: Value =
        serde_json::from_str(&read_stdin()?).map_err(|_| "hook input must be valid JSON")?;
    let (output, outcome, exit_code) = evaluate(host, &input)?;
    if let Some(state_dir) = state_dir {
        logging::record(state_dir, host, &input, outcome, exit_code)?;
    }
    if let Some(output) = output {
        print_json(&output)?;
    }
    Ok(0)
}

fn required_string<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|v| !v.trim().is_empty())
        .ok_or_else(|| format!("hook field {key} must be a nonempty string").into())
}

fn evaluate(host: &str, input: &Value) -> Result<(Option<Value>, &'static str, Option<i64>)> {
    if !input.is_object() {
        return Err("hook input must be a JSON object".into());
    }
    let event = required_string(input, "hook_event_name")?;
    required_string(input, "cwd")?;
    if required_string(input, "tool_name")? != "Bash" {
        return Err("this integration accepts Bash hook events only".into());
    }
    let tool_input = input
        .get("tool_input")
        .filter(|v| v.is_object())
        .ok_or("tool_input must be an object")?;
    let command = required_string(tool_input, "command")?;
    match event {
        "PreToolUse" => {
            if let Some(reason) = hook_checks::bash::blocked_reason(command) {
                Ok((
                    Some(json!({
                        "hookSpecificOutput": {
                            "hookEventName": "PreToolUse",
                            "permissionDecision": "deny",
                            "permissionDecisionReason": reason
                        }
                    })),
                    "denied",
                    None,
                ))
            } else {
                Ok((None, "requested", None))
            }
        }
        "PostToolUse" => {
            let response = input
                .get("tool_response")
                .ok_or("PostToolUse requires tool_response")?;
            let exit_code = match response.get("exit_code") {
                None | Some(Value::Null) => None,
                Some(value) => Some(
                    value
                        .as_i64()
                        .ok_or("reported exit_code must be an integer")?,
                ),
            };
            let outcome = if response.get("interrupted").and_then(Value::as_bool) == Some(true) {
                "interrupted"
            } else if response.get("isError").and_then(Value::as_bool) == Some(true) {
                "failed"
            } else if let Some(code) = exit_code {
                if code == 0 {
                    "exited_zero"
                } else {
                    "exited_nonzero"
                }
            } else if response.get("session_id").is_some_and(|v| !v.is_null()) {
                "running"
            } else {
                "exit_status_unavailable"
            };
            Ok((None, outcome, exit_code))
        }
        "PostToolUseFailure" if host == "claude" => {
            required_string(input, "error")?;
            let outcome = if input.get("is_interrupt").and_then(Value::as_bool) == Some(true) {
                "interrupted"
            } else {
                "failed"
            };
            Ok((None, outcome, None))
        }
        _ => Err("unsupported hook event for this host".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn payload(event: &str, command: &str) -> Value {
        json!({"hook_event_name":event,"tool_name":"Bash","tool_input":{"command":command},"cwd":"/repo"})
    }
    #[test]
    fn both_hosts_receive_native_denial_and_quiet_pass() {
        for host in ["claude", "codex"] {
            let (denied, outcome, _) =
                evaluate(host, &payload("PreToolUse", "git clean -fd")).unwrap();
            assert_eq!(outcome, "denied");
            assert_eq!(
                denied.unwrap()["hookSpecificOutput"]["permissionDecision"],
                "deny"
            );
            assert_eq!(
                evaluate(host, &payload("PreToolUse", "npm install"))
                    .unwrap()
                    .0,
                None
            );
        }
    }
    #[test]
    fn actual_result_is_distinguished_from_verification_claims() {
        let mut input = payload("PostToolUse", "echo cargo test");
        for (response, outcome) in [
            (json!({"exit_code":0}), "exited_zero"),
            (json!({"exit_code":1}), "exited_nonzero"),
            (json!({"session_id":123}), "running"),
            (json!({"interrupted":true}), "interrupted"),
            (
                json!({"stdout":"all tests passed"}),
                "exit_status_unavailable",
            ),
        ] {
            input["tool_response"] = response;
            assert_eq!(evaluate("codex", &input).unwrap().1, outcome);
        }
        // A later request reports only a request; no tree-verification flag exists.
        assert_eq!(
            evaluate("codex", &payload("PreToolUse", "cargo test"))
                .unwrap()
                .1,
            "requested"
        );
    }
    #[test]
    fn malformed_protocol_is_not_a_pass() {
        for input in [Value::Null, json!({}), json!({"tool_name":"Bash"})] {
            assert!(evaluate("codex", &input).is_err());
        }
        let mut input = payload("PreToolUse", "cargo test");
        input["tool_input"]["command"] = json!(false);
        assert!(evaluate("codex", &input).is_err());
        input = payload("Stop", "cargo test");
        assert!(evaluate("codex", &input).is_err());
    }
}
