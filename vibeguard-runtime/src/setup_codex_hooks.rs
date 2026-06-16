use crate::setup_support::{
    SetupResult, basename, display_home_path, home_dir, read_json_object, shell_quote, shell_split,
    write_json_atomic,
};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Eq)]
struct CodexSpec {
    event: String,
    matcher: Option<String>,
    script: String,
    timeout: Option<i64>,
}

pub fn codex_hooks_upsert(args: &[String]) -> SetupResult<()> {
    if args.len() != 3 {
        return Err(
            "Usage: vibeguard-runtime setup-codex-hooks-upsert <repo-dir> <hooks-file> <wrapper>"
                .into(),
        );
    }
    let repo_dir = Path::new(&args[0]);
    let hooks_path = Path::new(&args[1]);
    let wrapper = &args[2];
    let mut data = Value::Object(read_json_object(hooks_path, true)?);
    let before = serde_json::to_string(&data)?;
    ensure_hooks_root(&mut data)?;
    codex_prune_managed(&mut data, repo_dir);
    codex_prune_stale(&mut data);
    ensure_hooks_root(&mut data)?;
    let hooks = data["hooks"]
        .as_object_mut()
        .ok_or("hooks.json hooks must be an object")?;
    for spec in codex_specs(repo_dir)? {
        let entries = hooks.entry(spec.event.clone()).or_insert_with(|| json!([]));
        if !entries.is_array() {
            *entries = json!([]);
        }
        let entries_arr = entries.as_array_mut().expect("entries are array");
        let command = format!("bash {} {}", shell_quote(wrapper), spec.script);
        if !codex_has_entry(
            entries_arr,
            repo_dir,
            &command,
            spec.matcher.as_deref(),
            spec.timeout,
        ) {
            entries_arr.push(codex_build_entry(wrapper, &spec));
        }
    }
    if serde_json::to_string(&data)? != before {
        write_json_atomic(hooks_path, &data)?;
        println!("CHANGED");
    } else {
        println!("SKIP");
    }
    Ok(())
}

pub fn codex_hooks_remove(args: &[String]) -> SetupResult<()> {
    if args.len() != 2 {
        return Err(
            "Usage: vibeguard-runtime setup-codex-hooks-remove <repo-dir> <hooks-file>".into(),
        );
    }
    let hooks_path = Path::new(&args[1]);
    if !hooks_path.exists() {
        println!("SKIP");
        return Ok(());
    }
    let mut data = Value::Object(read_json_object(hooks_path, false)?);
    let before = serde_json::to_string(&data)?;
    codex_prune_managed(&mut data, Path::new(&args[0]));
    if serde_json::to_string(&data)? == before {
        println!("SKIP");
    } else {
        if data.as_object().is_some_and(|object| object.is_empty()) {
            std::fs::remove_file(hooks_path)?;
        } else {
            write_json_atomic(hooks_path, &data)?;
        }
        println!("CHANGED");
    }
    Ok(())
}

pub fn codex_hooks_check(args: &[String]) -> SetupResult<()> {
    if args.len() != 3 {
        return Err(
            "Usage: vibeguard-runtime setup-codex-hooks-check <repo-dir> <hooks-file> <wrapper>"
                .into(),
        );
    }
    let repo_dir = Path::new(&args[0]);
    let data = Value::Object(read_json_object(Path::new(&args[1]), false)?);
    let Some(hooks) = data.get("hooks").and_then(Value::as_object) else {
        std::process::exit(1);
    };
    for spec in codex_specs(repo_dir)? {
        let Some(entries) = hooks.get(&spec.event).and_then(Value::as_array) else {
            std::process::exit(1);
        };
        let command = format!("bash {} {}", shell_quote(&args[2]), spec.script);
        if !codex_has_entry(
            entries,
            repo_dir,
            &command,
            spec.matcher.as_deref(),
            spec.timeout,
        ) {
            std::process::exit(1);
        }
    }
    Ok(())
}

pub fn codex_hooks_count(args: &[String]) -> SetupResult<()> {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime setup-codex-hooks-count <hooks-file>".into());
    }
    let path = Path::new(&args[0]);
    if !path.exists() {
        println!("0");
        return Ok(());
    }
    let data = Value::Object(read_json_object(path, false)?);
    let total = data
        .get("hooks")
        .and_then(Value::as_object)
        .map(|hooks| {
            hooks
                .values()
                .filter_map(Value::as_array)
                .map(Vec::len)
                .sum::<usize>()
        })
        .unwrap_or(0);
    println!("{total}");
    Ok(())
}

pub fn codex_hooks_check_stale(args: &[String]) -> SetupResult<()> {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime setup-codex-hooks-check-stale <hooks-file>".into());
    }
    let hooks_path = Path::new(&args[0]);
    if !hooks_path.exists() {
        return Ok(());
    }
    let data = Value::Object(read_json_object(hooks_path, false)?);
    let findings = codex_stale_findings(&data, hooks_path);
    for finding in &findings {
        println!("{finding}");
    }
    if !findings.is_empty() {
        std::process::exit(1);
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
        let managed = codex_command_is_managed(repo_dir, command);
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

fn codex_specs(repo_dir: &Path) -> SetupResult<Vec<CodexSpec>> {
    let text = std::fs::read_to_string(repo_dir.join("hooks/manifest.json"))?;
    let manifest: Value = serde_json::from_str(&text)?;
    let hooks = manifest
        .get("hooks")
        .and_then(Value::as_array)
        .ok_or("hooks manifest must contain a hooks array")?;
    let mut specs = Vec::new();
    for item in hooks {
        let Some(item_obj) = item.as_object() else {
            return Err("each hook manifest entry must be an object".into());
        };
        let Some(codex) = item_obj.get("codex").and_then(Value::as_object) else {
            continue;
        };
        if codex.get("enabled").and_then(Value::as_bool) != Some(true) {
            continue;
        }
        if let Some(entries) = codex.get("entries").and_then(Value::as_array) {
            for entry in entries {
                let entry = entry
                    .as_object()
                    .ok_or("codex.entries must contain objects")?;
                specs.push(CodexSpec {
                    event: json_string(entry, "event")?,
                    matcher: entry
                        .get("matcher")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    script: entry
                        .get("script")
                        .or_else(|| codex.get("script"))
                        .and_then(Value::as_str)
                        .ok_or("codex entry script missing")?
                        .to_string(),
                    timeout: entry
                        .get("timeout")
                        .or_else(|| codex.get("timeout"))
                        .and_then(Value::as_i64),
                });
            }
        } else {
            specs.push(CodexSpec {
                event: json_string(codex, "event")?,
                matcher: codex
                    .get("matcher")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                script: json_string(codex, "script")?,
                timeout: codex.get("timeout").and_then(Value::as_i64),
            });
        }
    }
    Ok(specs)
}

fn json_string(object: &serde_json::Map<String, Value>, key: &str) -> SetupResult<String> {
    object
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| format!("missing string field: {key}").into())
}

fn ensure_hooks_root(data: &mut Value) -> SetupResult<()> {
    if data.get("hooks").and_then(Value::as_object).is_none() {
        data.as_object_mut()
            .ok_or("hooks.json root must be an object")?
            .insert("hooks".to_string(), json!({}));
    }
    Ok(())
}

fn codex_prune_managed(data: &mut Value, repo_dir: &Path) {
    let Some(hooks) = data.get_mut("hooks").and_then(Value::as_object_mut) else {
        return;
    };
    for entries in hooks.values_mut() {
        let Some(entries) = entries.as_array_mut() else {
            continue;
        };
        let mut next_entries = Vec::new();
        for entry in std::mem::take(entries) {
            let Some(entry_obj) = entry.as_object() else {
                next_entries.push(entry);
                continue;
            };
            let Some(hook_entries) = entry_obj.get("hooks").and_then(Value::as_array) else {
                next_entries.push(entry);
                continue;
            };
            let kept: Vec<Value> = hook_entries
                .iter()
                .filter(|hook| {
                    let command = hook.get("command").and_then(Value::as_str).unwrap_or("");
                    !codex_command_is_managed(repo_dir, command)
                })
                .cloned()
                .collect();
            if kept.len() == hook_entries.len() {
                next_entries.push(entry);
            } else if !kept.is_empty() {
                let mut next = entry_obj.clone();
                next.insert("hooks".to_string(), Value::Array(kept));
                next_entries.push(Value::Object(next));
            }
        }
        *entries = next_entries;
    }
    hooks.retain(|_, value| value.as_array().is_some_and(|items| !items.is_empty()));
    if hooks.is_empty() {
        data.as_object_mut().expect("object").remove("hooks");
    }
}

fn codex_prune_stale(data: &mut Value) {
    let Some(hooks) = data.get_mut("hooks").and_then(Value::as_object_mut) else {
        return;
    };
    for entries in hooks.values_mut() {
        let Some(entries) = entries.as_array_mut() else {
            continue;
        };
        let mut next_entries = Vec::new();
        for entry in std::mem::take(entries) {
            let Some(entry_obj) = entry.as_object() else {
                next_entries.push(entry);
                continue;
            };
            let Some(hook_entries) = entry_obj.get("hooks").and_then(Value::as_array) else {
                next_entries.push(entry);
                continue;
            };
            let kept: Vec<Value> = hook_entries
                .iter()
                .filter(|hook| {
                    let command = hook.get("command").and_then(Value::as_str).unwrap_or("");
                    codex_direct_installed_hook_target(command).is_none()
                        && codex_hook_target(command).is_none_or(|target| target.exists())
                })
                .cloned()
                .collect();
            if kept.len() == hook_entries.len() {
                next_entries.push(entry);
            } else if !kept.is_empty() {
                let mut next = entry_obj.clone();
                next.insert("hooks".to_string(), Value::Array(kept));
                next_entries.push(Value::Object(next));
            }
        }
        *entries = next_entries;
    }
}

fn codex_build_entry(wrapper: &str, spec: &CodexSpec) -> Value {
    let mut hook = serde_json::Map::new();
    hook.insert("type".to_string(), Value::String("command".to_string()));
    hook.insert(
        "command".to_string(),
        Value::String(format!("bash {} {}", shell_quote(wrapper), spec.script)),
    );
    if let Some(timeout) = spec.timeout {
        hook.insert("timeout".to_string(), Value::Number(timeout.into()));
    }
    let mut entry = serde_json::Map::new();
    entry.insert("hooks".to_string(), Value::Array(vec![Value::Object(hook)]));
    if let Some(matcher) = &spec.matcher {
        if !matcher.is_empty() {
            entry.insert("matcher".to_string(), Value::String(matcher.clone()));
        }
    }
    Value::Object(entry)
}

fn codex_has_entry(
    entries: &[Value],
    repo_dir: &Path,
    command: &str,
    matcher: Option<&str>,
    timeout: Option<i64>,
) -> bool {
    entries.iter().any(|entry| {
        let Some(entry_obj) = entry.as_object() else {
            return false;
        };
        if entry_obj.get("matcher").and_then(Value::as_str) != matcher {
            return false;
        }
        let Some(hooks) = entry_obj.get("hooks").and_then(Value::as_array) else {
            return false;
        };
        hooks.iter().any(|hook| {
            let hook_command = hook.get("command").and_then(Value::as_str).unwrap_or("");
            codex_command_is_managed(repo_dir, hook_command)
                && hook_command == command
                && hook.get("type").and_then(Value::as_str) == Some("command")
                && match timeout {
                    Some(expected) => hook.get("timeout").and_then(Value::as_i64) == Some(expected),
                    None => hook.get("timeout").is_none(),
                }
        })
    })
}

fn codex_command_is_managed(repo_dir: &Path, command: &str) -> bool {
    let scripts = codex_managed_scripts(repo_dir);
    let parts = shell_split(command);
    for (idx, token) in parts.iter().enumerate() {
        if basename(token) == "run-hook-codex.sh" {
            if let Some(next) = parts.get(idx + 1) {
                if scripts.contains(basename(next)) {
                    return true;
                }
            }
        }
        let base = basename(token);
        if scripts.contains(base) {
            return true;
        }
    }
    false
}

fn codex_managed_scripts(repo_dir: &Path) -> BTreeSet<String> {
    let mut scripts = BTreeSet::new();
    if let Ok(specs) = codex_specs(repo_dir) {
        scripts.extend(specs.into_iter().map(|spec| spec.script));
    }
    if let Ok(text) = std::fs::read_to_string(repo_dir.join("hooks/manifest.json")) {
        if let Ok(value) = serde_json::from_str::<Value>(&text) {
            if let Some(hooks) = value.get("hooks").and_then(Value::as_array) {
                for item in hooks {
                    if let Some(script) = item.get("script").and_then(Value::as_str) {
                        scripts.insert(script.to_string());
                    }
                }
            }
        }
    }
    scripts
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
            let matcher = entry_obj
                .get("matcher")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .unwrap_or("<none>")
                .to_string();
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

fn codex_stale_findings(data: &Value, config: &Path) -> Vec<String> {
    codex_hook_records(data)
        .into_iter()
        .filter_map(|(event, matcher, hook)| {
            let command = hook.get("command").and_then(Value::as_str).unwrap_or("");
            let target = if let Some(target) = codex_direct_installed_hook_target(command) {
                target
            } else {
                let target = codex_hook_target(command)?;
                if target.exists() {
                    return None;
                }
                target
            };
            Some(format!(
                "stale Codex hook command: config={} event={event} matcher={matcher} command_path={} repair=bash setup.sh --yes",
                display_home_path(config),
                target.display()
            ))
        })
        .collect()
}

fn codex_direct_installed_hook_target(command: &str) -> Option<PathBuf> {
    let home = home_dir()?;
    shell_split(command).into_iter().find_map(|token| {
        let path = codex_expand_path(&token, &home)?;
        path.to_string_lossy()
            .contains("/.vibeguard/installed/hooks/")
            .then_some(path)
    })
}

fn codex_hook_target(command: &str) -> Option<PathBuf> {
    let home = home_dir()?;
    let parts = shell_split(command);
    for (idx, token) in parts.iter().enumerate() {
        let path = codex_expand_path(token, &home)?;
        if path
            .to_string_lossy()
            .ends_with("/.vibeguard/run-hook-codex.sh")
        {
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

fn codex_expand_path(token: &str, home: &Path) -> Option<PathBuf> {
    token
        .strip_prefix("~/")
        .map(|tail| home.join(tail))
        .or_else(|| token.strip_prefix("$HOME/").map(|tail| home.join(tail)))
        .or_else(|| token.strip_prefix("${HOME}/").map(|tail| home.join(tail)))
        .or_else(|| token.starts_with('/').then(|| PathBuf::from(token)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo_dir() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("..")
    }

    #[test]
    fn prune_current_managed_keeps_third_party_hooks_in_mixed_entry() {
        let repo_dir = repo_dir();
        let mut data = json!({
            "hooks": {
                "PreToolUse": [
                    {
                        "matcher": "Bash",
                        "hooks": [
                            {
                                "type": "command",
                                "command": "bash /tmp/run-hook-codex.sh vibeguard-pre-bash-guard.sh"
                            },
                            {
                                "type": "command",
                                "command": "bash /tmp/third-party.sh"
                            }
                        ]
                    }
                ]
            }
        });

        codex_prune_managed(&mut data, &repo_dir);

        let hooks = data
            .pointer("/hooks/PreToolUse/0/hooks")
            .and_then(Value::as_array);
        assert_eq!(hooks.map(Vec::len), Some(1));
        assert_eq!(
            hooks
                .and_then(|items| items.first())
                .and_then(|hook| hook.get("command"))
                .and_then(Value::as_str),
            Some("bash /tmp/third-party.sh")
        );
    }

    #[test]
    fn built_entries_preserve_matcher_and_timeout() {
        let spec = CodexSpec {
            event: "Stop".to_string(),
            matcher: None,
            script: "vibeguard-stop-guard.sh".to_string(),
            timeout: Some(15),
        };

        let entry = codex_build_entry("/tmp/run-hook-codex.sh", &spec);
        assert_eq!(entry.get("matcher"), None);
        let hook = entry
            .get("hooks")
            .and_then(Value::as_array)
            .and_then(|items| items.first());
        assert_eq!(
            hook.and_then(|value| value.get("command"))
                .and_then(Value::as_str),
            Some("bash /tmp/run-hook-codex.sh vibeguard-stop-guard.sh")
        );
        assert_eq!(
            hook.and_then(|value| value.get("timeout"))
                .and_then(Value::as_i64),
            Some(15)
        );
    }

    #[test]
    fn managed_entry_check_requires_expected_timeout() {
        let repo_dir = repo_dir();
        let command = "bash /tmp/run-hook-codex.sh vibeguard-stop-guard.sh";
        let entries = vec![json!({
            "hooks": [
                {
                    "type": "command",
                    "command": command,
                    "timeout": 99
                }
            ]
        })];

        assert!(!codex_has_entry(
            &entries,
            &repo_dir,
            command,
            None,
            Some(15)
        ));
        assert!(codex_has_entry(
            &entries,
            &repo_dir,
            command,
            None,
            Some(99)
        ));
    }
}
