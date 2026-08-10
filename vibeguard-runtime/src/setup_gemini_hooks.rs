use crate::setup_support::{
    SetupResult, read_json_object, shell_quote, simple_unified_diff, write_json_atomic_private,
};
use serde_json::{Value, json};
use std::path::Path;

const EVENT: &str = "BeforeTool";
const MANAGED_NAME: &str = "vibeguard-before-tool";
const MATCHER: &str = "^(run_shell_command|write_file|replace)$";
const TIMEOUT_MS: u64 = 20_000;

pub(crate) fn upsert(args: &[String]) -> SetupResult<()> {
    if !(args.len() == 2 || (args.len() == 3 && args[2] == "--dry-run")) {
        return Err(
            "Usage: vibeguard-runtime setup-gemini-hooks-upsert <settings-file> <wrapper> [--dry-run]"
                .into(),
        );
    }
    let path = Path::new(&args[0]);
    let wrapper = &args[1];
    let dry_run = args.get(2).is_some_and(|arg| arg == "--dry-run");
    let before_text = std::fs::read_to_string(path).unwrap_or_default();
    let mut data = Value::Object(read_json_object(path, true)?);
    remove_managed(&mut data)?;
    before_tool_entries(&mut data)?.push(managed_entry(wrapper));
    let after_text = serde_json::to_string_pretty(&data)? + "\n";
    if after_text == before_text {
        println!("SKIP");
    } else if dry_run {
        print!("{}", simple_unified_diff(path, &before_text, &after_text));
        println!("CHANGED");
    } else {
        write_json_atomic_private(path, &data)?;
        println!("CHANGED");
    }
    Ok(())
}

pub(crate) fn remove(args: &[String]) -> SetupResult<()> {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime setup-gemini-hooks-remove <settings-file>".into());
    }
    let path = Path::new(&args[0]);
    if !path.exists() {
        println!("SKIP");
        return Ok(());
    }
    let mut data = Value::Object(read_json_object(path, false)?);
    let before = serde_json::to_string(&data)?;
    remove_managed(&mut data)?;
    if serde_json::to_string(&data)? == before {
        println!("SKIP");
    } else {
        write_json_atomic_private(path, &data)?;
        println!("CHANGED");
    }
    Ok(())
}

pub(crate) fn check(args: &[String]) -> SetupResult<()> {
    if args.len() != 2 {
        return Err(
            "Usage: vibeguard-runtime setup-gemini-hooks-check <settings-file> <wrapper>".into(),
        );
    }
    let data = Value::Object(read_json_object(Path::new(&args[0]), false)?);
    let enabled = match data.pointer("/hooksConfig/enabled") {
        None | Some(Value::Bool(true)) => true,
        Some(Value::Bool(false)) | Some(_) => false,
    };
    let disabled_names_valid = match data.pointer("/hooksConfig/disabled") {
        None => true,
        Some(Value::Array(names)) => {
            names.iter().all(Value::is_string)
                && !names.iter().any(|name| name.as_str() == Some(MANAGED_NAME))
        }
        Some(_) => false,
    };
    if !enabled || !disabled_names_valid {
        std::process::exit(1);
    }
    let expected = managed_entry(&args[1]);
    let count = data
        .pointer("/hooks/BeforeTool")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|entry| contains_managed_hook(entry))
        .count();
    if count != 1
        || !data
            .pointer("/hooks/BeforeTool")
            .and_then(Value::as_array)
            .is_some_and(|entries| entries.contains(&expected))
    {
        std::process::exit(1);
    }
    Ok(())
}

fn before_tool_entries(data: &mut Value) -> SetupResult<&mut Vec<Value>> {
    let root = data
        .as_object_mut()
        .ok_or("Gemini settings root must be an object")?;
    let hooks = root
        .entry("hooks")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or("Gemini settings hooks must be an object")?;
    hooks
        .entry(EVENT)
        .or_insert_with(|| json!([]))
        .as_array_mut()
        .ok_or_else(|| "Gemini settings hooks.BeforeTool must be an array".into())
}

fn managed_entry(wrapper: &str) -> Value {
    json!({
        "matcher": MATCHER,
        "sequential": true,
        "hooks": [{
            "name": MANAGED_NAME,
            "type": "command",
            "command": format!(
                "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash {}",
                shell_quote(wrapper)
            ),
            "timeout": TIMEOUT_MS,
            "description": "VibeGuard policy checks for Gemini CLI tool calls"
        }]
    })
}

fn contains_managed_hook(entry: &Value) -> bool {
    entry
        .get("hooks")
        .and_then(Value::as_array)
        .is_some_and(|hooks| hooks.iter().any(is_managed_hook))
}

fn is_managed_hook(hook: &Value) -> bool {
    hook.get("name").and_then(Value::as_str) == Some(MANAGED_NAME)
}

fn remove_managed(data: &mut Value) -> SetupResult<()> {
    let Some(root) = data.as_object_mut() else {
        return Err("Gemini settings root must be an object".into());
    };
    let Some(hooks_value) = root.get_mut("hooks") else {
        return Ok(());
    };
    let hooks = hooks_value
        .as_object_mut()
        .ok_or("Gemini settings hooks must be an object")?;
    let Some(entries_value) = hooks.get_mut(EVENT) else {
        return Ok(());
    };
    let entries = entries_value
        .as_array_mut()
        .ok_or("Gemini settings hooks.BeforeTool must be an array")?;
    let mut retained = Vec::new();
    for entry in std::mem::take(entries) {
        retained.extend(remove_managed_from_entry(entry));
    }
    *entries = retained;
    if entries.is_empty() {
        hooks.remove(EVENT);
    }
    if hooks.is_empty() {
        root.remove("hooks");
    }
    Ok(())
}

fn remove_managed_from_entry(mut entry: Value) -> Option<Value> {
    let Some(object) = entry.as_object_mut() else {
        return Some(entry);
    };
    let Some(hooks) = object.get_mut("hooks").and_then(Value::as_array_mut) else {
        return Some(entry);
    };
    hooks.retain(|hook| !is_managed_hook(hook));
    (!hooks.is_empty()).then_some(entry)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn removal_preserves_unrelated_hooks_in_the_same_group() {
        let mut data = json!({"hooks": {"BeforeTool": [{
            "matcher": ".*",
            "hooks": [
                {"name": MANAGED_NAME, "type": "command", "command": "old"},
                {"name": "custom", "type": "command", "command": "custom"}
            ]
        }]}});
        remove_managed(&mut data).unwrap();
        assert_eq!(
            data.pointer("/hooks/BeforeTool/0/hooks/0/name")
                .and_then(Value::as_str),
            Some("custom")
        );
    }
}
