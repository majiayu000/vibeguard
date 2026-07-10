use crate::setup_codex_hooks::{
    codex_command_is_managed, codex_expand_path, codex_managed_scripts,
};
use crate::setup_support::{
    SetupResult, basename, display_home_path, home_dir, read_json_object, shell_split,
    write_json_atomic,
};
use serde_json::Value;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Eq)]
enum CodexCommandState {
    ManagedVibeguard,
    UnmanagedValid { target: PathBuf },
    UnmanagedMissingTarget { target: PathBuf },
    UnmanagedUnresolved,
}

pub fn codex_hooks_check_stale(args: &[String]) -> SetupResult<()> {
    let (repo_dir, hooks_path) = match args {
        [hooks_file] => (None, Path::new(hooks_file)),
        [repo_dir, hooks_file] => (Some(Path::new(repo_dir)), Path::new(hooks_file)),
        _ => {
            return Err(
                "Usage: vibeguard-runtime setup-codex-hooks-check-stale [repo-dir] <hooks-file>"
                    .into(),
            );
        }
    };
    let managed_scripts = repo_dir.map(codex_managed_scripts).transpose()?;
    if !hooks_path.exists() {
        return Ok(());
    }
    let data = Value::Object(read_json_object(hooks_path, false)?);
    let findings = codex_stale_findings(&data, hooks_path, managed_scripts.as_ref());
    for finding in &findings {
        println!("{finding}");
    }
    if !findings.is_empty() {
        std::process::exit(1);
    }
    Ok(())
}

pub fn codex_hooks_prune_stale_unmanaged(args: &[String]) -> SetupResult<()> {
    if args.len() < 2 {
        return Err(
            "Usage: vibeguard-runtime setup-codex-hooks-prune-stale-unmanaged <repo-dir> <hooks-file> [event...]"
                .into(),
        );
    }
    let repo_dir = Path::new(&args[0]);
    let hooks_path = Path::new(&args[1]);
    let managed_scripts = codex_managed_scripts(repo_dir)?;
    if !hooks_path.exists() {
        println!("SKIP");
        return Ok(());
    }
    let events: BTreeSet<String> = if args.len() > 2 {
        args[2..].iter().cloned().collect()
    } else {
        ["PreToolUse", "PermissionRequest"]
            .into_iter()
            .map(str::to_string)
            .collect()
    };
    let mut data = Value::Object(read_json_object(hooks_path, false)?);
    let removed = codex_prune_stale_unmanaged(&mut data, &managed_scripts, hooks_path, &events);
    for finding in &removed {
        println!("{finding}");
    }
    if removed.is_empty() {
        println!("SKIP");
    } else {
        write_json_atomic(hooks_path, &data)?;
        println!("CHANGED");
    }
    Ok(())
}

pub fn codex_hooks_check_timeouts(args: &[String]) -> SetupResult<()> {
    if args.len() != 2 {
        return Err(
            "Usage: vibeguard-runtime setup-codex-hooks-check-timeouts <repo-dir> <hooks-file>"
                .into(),
        );
    }
    let repo_dir = Path::new(&args[0]);
    let hooks_path = Path::new(&args[1]);
    let managed_scripts = codex_managed_scripts(repo_dir)?;
    if !hooks_path.exists() {
        return Ok(());
    }
    let data = Value::Object(read_json_object(hooks_path, false)?);
    let mut findings = Vec::new();
    for (event, matcher, hook) in codex_hook_records(&data) {
        let command = hook.get("command").and_then(Value::as_str).unwrap_or("");
        if command.is_empty()
            || hook
                .get("timeout")
                .and_then(Value::as_i64)
                .is_some_and(|v| v > 0)
        {
            continue;
        }
        let managed = codex_command_is_managed(&managed_scripts, command);
        let state = if managed { "managed" } else { "unmanaged" };
        let repair = if managed {
            "bash setup.sh --yes"
        } else {
            "add timeout or consult hook owner"
        };
        findings.push(format!(
            "{state} Codex hook without timeout: config={} event={event} matcher={matcher} command={command} repair={repair}",
            display_home_path(hooks_path)
        ));
    }
    for finding in &findings {
        println!("{finding}");
    }
    if !findings.is_empty() {
        std::process::exit(1);
    }
    Ok(())
}

fn codex_stale_findings(
    data: &Value,
    config: &Path,
    managed_scripts: Option<&BTreeSet<String>>,
) -> Vec<String> {
    codex_hook_records(data)
        .into_iter()
        .filter_map(|(event, matcher, hook)| {
            let command = hook.get("command").and_then(Value::as_str).unwrap_or("");
            if let Some(target) = codex_installed_hook_target(command) {
                if target.exists() {
                    return None;
                }
                return Some(format!(
                    "stale Codex hook command: config={} event={event} matcher={matcher} command_path={} repair=bash setup.sh --yes",
                    display_home_path(config),
                    target.display()
                ));
            }
            match codex_command_state(managed_scripts, command) {
                CodexCommandState::UnmanagedMissingTarget { target } => {
                    let label = if codex_event_is_blocking(&event) {
                        "repair-required unmanaged Codex blocking hook"
                    } else {
                        "stale unmanaged Codex hook"
                    };
                    Some(format!(
                        "{label}: config={} event={event} matcher={matcher} command={command} command_path={} repair=bash setup.sh --yes --repair-stale-unmanaged-hooks",
                        display_home_path(config),
                        target.display()
                    ))
                }
                _ => None,
            }
        })
        .collect()
}

fn codex_prune_stale_unmanaged(
    data: &mut Value,
    managed_scripts: &BTreeSet<String>,
    config: &Path,
    events: &BTreeSet<String>,
) -> Vec<String> {
    let mut removed = Vec::new();
    let Some(hooks) = data.get_mut("hooks").and_then(Value::as_object_mut) else {
        return removed;
    };
    for (event, entries) in hooks.iter_mut() {
        if !events.contains(event) {
            continue;
        }
        let Some(entries) = entries.as_array_mut() else {
            continue;
        };
        let mut next_entries = Vec::new();
        for entry in std::mem::take(entries) {
            let Some(entry_obj) = entry.as_object() else {
                next_entries.push(entry);
                continue;
            };
            let matcher = codex_entry_matcher(entry_obj);
            let Some(hook_entries) = entry_obj.get("hooks").and_then(Value::as_array) else {
                next_entries.push(entry);
                continue;
            };
            let mut kept_hooks = Vec::new();
            for hook in hook_entries {
                let command = hook.get("command").and_then(Value::as_str).unwrap_or("");
                match codex_command_state(Some(managed_scripts), command) {
                    CodexCommandState::UnmanagedMissingTarget { target } => {
                        removed.push(format!(
                            "removed stale unmanaged Codex hook: config={} event={event} matcher={matcher} command={command} command_path={}",
                            display_home_path(config),
                            target.display()
                        ));
                    }
                    _ => kept_hooks.push(hook.clone()),
                }
            }
            if kept_hooks.len() == hook_entries.len() {
                next_entries.push(entry);
            } else if !kept_hooks.is_empty() {
                let mut next = entry_obj.clone();
                next.insert("hooks".to_string(), Value::Array(kept_hooks));
                next_entries.push(Value::Object(next));
            }
        }
        *entries = next_entries;
    }
    hooks.retain(|_, value| value.as_array().is_some_and(|items| !items.is_empty()));
    if hooks.is_empty() {
        data.as_object_mut().expect("object").remove("hooks");
    }
    removed
}

fn codex_hook_records(data: &Value) -> Vec<(String, String, serde_json::Map<String, Value>)> {
    let mut records = Vec::new();
    let Some(hooks) = data.get("hooks").and_then(Value::as_object) else {
        return records;
    };
    for (event, entries) in hooks {
        let Some(entries) = entries.as_array() else {
            continue;
        };
        for entry in entries {
            let Some(entry_obj) = entry.as_object() else {
                continue;
            };
            let matcher = codex_entry_matcher(entry_obj);
            let Some(hook_entries) = entry_obj.get("hooks").and_then(Value::as_array) else {
                continue;
            };
            for hook in hook_entries {
                if let Some(hook_obj) = hook.as_object() {
                    records.push((event.clone(), matcher.clone(), hook_obj.clone()));
                }
            }
        }
    }
    records
}

fn codex_entry_matcher(entry_obj: &serde_json::Map<String, Value>) -> String {
    entry_obj
        .get("matcher")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .unwrap_or("<none>")
        .to_string()
}

fn codex_event_is_blocking(event: &str) -> bool {
    matches!(event, "PreToolUse" | "PermissionRequest")
}

fn codex_command_state(
    managed_scripts: Option<&BTreeSet<String>>,
    command: &str,
) -> CodexCommandState {
    if managed_scripts.is_some_and(|scripts| codex_command_is_managed(scripts, command)) {
        return CodexCommandState::ManagedVibeguard;
    }
    let Some(target) = codex_unmanaged_command_target(command) else {
        return CodexCommandState::UnmanagedUnresolved;
    };
    if target.exists() {
        CodexCommandState::UnmanagedValid { target }
    } else {
        CodexCommandState::UnmanagedMissingTarget { target }
    }
}

fn codex_unmanaged_command_target(command: &str) -> Option<PathBuf> {
    let home = home_dir()?;
    let parts = shell_split(command);
    let start = codex_command_start_after_env(&parts)?;
    let first = parts.get(start)?;
    if let Some(path) = codex_expand_path(first, &home) {
        return Some(path);
    }
    if !codex_token_is_interpreter(first) {
        return None;
    }
    parts.iter().skip(start + 1).find_map(|token| {
        if token.starts_with('-') || codex_token_is_env_assignment(token) {
            None
        } else {
            codex_expand_path(token, &home)
        }
    })
}

fn codex_command_start_after_env(parts: &[String]) -> Option<usize> {
    let mut idx = 0;
    if parts.get(idx).is_some_and(|part| basename(part) == "env") {
        idx += 1;
    }
    while parts
        .get(idx)
        .is_some_and(|part| codex_token_is_env_assignment(part))
    {
        idx += 1;
    }
    (idx < parts.len()).then_some(idx)
}

fn codex_token_is_env_assignment(token: &str) -> bool {
    let Some((name, _)) = token.split_once('=') else {
        return false;
    };
    !name.is_empty()
        && name
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
}

fn codex_token_is_interpreter(token: &str) -> bool {
    matches!(
        basename(token),
        "node"
            | "bash"
            | "sh"
            | "python"
            | "python3"
            | "python2"
            | "ruby"
            | "perl"
            | "deno"
            | "bun"
    )
}

fn codex_installed_hook_target(command: &str) -> Option<PathBuf> {
    let home = home_dir()?;
    let parts = shell_split(command);
    for (idx, token) in parts.iter().enumerate() {
        let Some(path) = codex_expand_path(token, &home) else {
            continue;
        };
        let path_text = path.to_string_lossy();
        if path_text.contains("/.vibeguard/installed/hooks/") {
            return Some(path);
        }
        if path_text.ends_with("/.vibeguard/run-hook-codex.sh") {
            let script = parts.get(idx + 1)?;
            if !script.contains('/') {
                let installed = path.parent()?.join("installed/hooks").join(script);
                if installed.parent().is_some_and(Path::exists) {
                    return Some(installed);
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_home() -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let path = std::env::temp_dir().join(format!("vg-codex-health-{stamp}"));
        fs::create_dir_all(&path).expect("temp home");
        unsafe {
            std::env::set_var("HOME", &path);
        }
        path
    }

    #[test]
    fn unmanaged_target_detects_direct_interpreter_and_env_forms() {
        let home = temp_home();
        let existing = home.join("hook.sh");
        fs::write(&existing, "#!/usr/bin/env bash\n").expect("write hook");

        assert_eq!(
            codex_command_state(None, &format!("bash {}", existing.display())),
            CodexCommandState::UnmanagedValid { target: existing }
        );
        assert!(matches!(
            codex_command_state(None, "env FOO=1 node /existing/non-vibeguard.js"),
            CodexCommandState::UnmanagedMissingTarget { .. }
        ));
        assert_eq!(
            codex_command_state(None, "node --eval 'console.log(1)'"),
            CodexCommandState::UnmanagedUnresolved
        );
    }
}
