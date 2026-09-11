use crate::setup::hook_command_identity;
use crate::setup::support::{basename, display_home_path, home_dir, shell_split};
use serde_json::Value;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

pub(super) fn settings_entry_has_script(entry: &Value, script: &str) -> bool {
    entry
        .get("hooks")
        .and_then(Value::as_array)
        .is_some_and(|hooks| {
            hooks
                .iter()
                .any(|hook| settings_hook_is_script(hook, script))
        })
}

pub(super) fn settings_hook_is_script(hook: &Value, script: &str) -> bool {
    hook.get("command")
        .and_then(Value::as_str)
        .is_some_and(|command| {
            hook_command_identity::command_invokes_script(command, script, "run-hook.sh")
        })
}

pub(super) fn settings_hook_managed_script<'a>(
    hook: &Value,
    managed_scripts: &'a BTreeSet<String>,
) -> Option<&'a str> {
    hook.get("command")
        .and_then(Value::as_str)
        .and_then(|command| {
            hook_command_identity::managed_script_from_command(
                command,
                managed_scripts,
                "run-hook.sh",
            )
        })
}

pub(super) fn settings_is_canonical(command: &str, script: &str) -> bool {
    let parts = shell_split(command);
    if parts.len() == 3 {
        return parts.first().is_some_and(|part| basename(part) == "bash")
            && parts
                .get(1)
                .is_some_and(|part| part.ends_with("/.vibeguard/run-hook.sh"))
            && parts.get(2).is_some_and(|part| part == script);
    }
    false
}

pub(super) fn settings_stale_findings(data: &Value, config: &Path) -> Vec<String> {
    let mut findings = Vec::new();
    let Some(hooks) = data.get("hooks").and_then(Value::as_object) else {
        return findings;
    };
    for (event, entries) in hooks {
        let Some(entries) = entries.as_array() else {
            continue;
        };
        for entry in entries {
            let matcher = entry
                .get("matcher")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .unwrap_or("<none>");
            let Some(hook_entries) = entry.get("hooks").and_then(Value::as_array) else {
                continue;
            };
            for hook in hook_entries {
                let command = hook.get("command").and_then(Value::as_str).unwrap_or("");
                let target = if let Some(target) = settings_direct_installed_hook_target(command) {
                    target
                } else {
                    let Some(target) = settings_hook_target(command, "run-hook.sh") else {
                        continue;
                    };
                    if target.exists() {
                        continue;
                    }
                    target
                };
                findings.push(format!(
                    "stale Claude hook command: config={} event={event} matcher={matcher} command_path={} repair=bash setup.sh --yes",
                    display_home_path(config),
                    target.display()
                ));
            }
        }
    }
    findings
}

pub(super) fn settings_direct_installed_hook_target(command: &str) -> Option<PathBuf> {
    let home = home_dir()?;
    shell_split(command).into_iter().find_map(|token| {
        let path = settings_expand_path(&token, &home)?;
        path.to_string_lossy()
            .contains("/.vibeguard/installed/hooks/")
            .then_some(path)
    })
}

pub(super) fn settings_hook_target(command: &str, wrapper_name: &str) -> Option<PathBuf> {
    let home = home_dir()?;
    let parts = shell_split(command);
    for (idx, token) in parts.iter().enumerate() {
        let path = settings_expand_path(token, &home)?;
        if path
            .to_string_lossy()
            .ends_with(&format!("/.vibeguard/{wrapper_name}"))
        {
            let script = parts.get(idx + 1)?;
            if !script.contains('/') {
                let installed = path.parent()?.join("installed/hooks").join(script);
                if installed.parent().is_some_and(Path::exists) {
                    return Some(installed);
                };
            }
        }
    }
    None
}

fn settings_expand_path(token: &str, home: &Path) -> Option<PathBuf> {
    token
        .strip_prefix("~/")
        .map(|tail| home.join(tail))
        .or_else(|| token.strip_prefix("$HOME/").map(|tail| home.join(tail)))
        .or_else(|| token.strip_prefix("${HOME}/").map(|tail| home.join(tail)))
        .or_else(|| token.starts_with('/').then(|| PathBuf::from(token)))
}
