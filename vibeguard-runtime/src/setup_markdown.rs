use crate::setup_support::{
    SetupResult, basename, display_home_path, home_dir, read_json_object, shell_quote, shell_split,
    simple_unified_diff, write_json_atomic, write_text_atomic,
};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

mod hook_identity;

const START: &str = "<!-- vibeguard-start -->";
const END: &str = "<!-- vibeguard-end -->";
const RULE_COUNT_PLACEHOLDER: &str = "__VIBEGUARD_RULE_COUNT__";

pub fn diff_inject(args: &[String]) -> SetupResult<()> {
    if args.len() != 4 {
        return Err("Usage: vibeguard-runtime setup-md-diff-inject <target-file> <rules-file> <repo-dir> <rule-count>".into());
    }
    let (action, original, content) =
        render_injected(Path::new(&args[0]), Path::new(&args[1]), &args[2], &args[3])?;
    if original == content {
        println!("SKIP");
    } else {
        print!(
            "{}",
            simple_unified_diff(Path::new(&args[0]), &original, &content)
        );
        println!("{action}");
    }
    Ok(())
}

pub fn inject(args: &[String]) -> SetupResult<()> {
    if args.len() != 4 {
        return Err("Usage: vibeguard-runtime setup-md-inject <target-file> <rules-file> <repo-dir> <rule-count>".into());
    }
    let (action, _original, content) =
        render_injected(Path::new(&args[0]), Path::new(&args[1]), &args[2], &args[3])?;
    write_text_atomic(Path::new(&args[0]), &content)?;
    println!("{action}");
    Ok(())
}

pub fn remove(args: &[String]) -> SetupResult<()> {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime setup-md-remove <target-file>".into());
    }
    let path = Path::new(&args[0]);
    if !path.exists() {
        println!("NOT_FOUND");
        return Ok(());
    }

    let original = std::fs::read_to_string(path)?;
    if let Some((start, end_after)) = marker_range(&original) {
        let before = original[..start].trim_end();
        let after = original[end_after..].trim_start_matches('\n');
        let mut content = before.to_string();
        if !after.is_empty() {
            if !content.is_empty() {
                content.push_str("\n\n");
            }
            content.push_str(after);
        }
        content = content.trim_end().to_string() + "\n";
        write_text_atomic(path, &content)?;
        println!("REMOVED");
        return Ok(());
    }

    println!("NOT_FOUND");
    Ok(())
}

fn render_injected(
    target_file: &Path,
    rules_file: &Path,
    repo_dir: &str,
    rule_count: &str,
) -> SetupResult<(String, String, String)> {
    if rule_count.parse::<u64>().is_err() {
        return Err(format!("Invalid rule count: {rule_count}").into());
    }
    let rules = std::fs::read_to_string(rules_file)?
        .replace("__VIBEGUARD_DIR__", repo_dir)
        .replace(RULE_COUNT_PLACEHOLDER, rule_count);
    let original = std::fs::read_to_string(target_file).unwrap_or_default();

    if marker_range(&original).is_some() {
        let content = replace_managed_block(&original, &rules);
        return Ok(("UPDATED".to_string(), original, content));
    }
    let base = original.trim_end();
    let content = if base.is_empty() {
        format!("{}\n", rules.trim())
    } else {
        format!("{base}\n\n{}\n", rules.trim())
    };
    Ok(("APPENDED".to_string(), original, content))
}

fn replace_managed_block(original: &str, rules: &str) -> String {
    let Some((start, end_after)) = marker_range(original) else {
        return original.to_string();
    };
    let before = original[..start].trim_end();
    let after = original[end_after..].trim_start_matches('\n');
    let mut content = String::new();
    if !before.is_empty() {
        content.push_str(before);
        content.push_str("\n\n");
    }
    content.push_str(rules.trim());
    content.push('\n');
    if !after.is_empty() {
        content.push('\n');
        content.push_str(after);
    }
    content
}

fn marker_range(text: &str) -> Option<(usize, usize)> {
    let start = text.find(START)?;
    let end = text[start..].find(END)? + start;
    Some((start, end + END.len()))
}

#[derive(Clone, Debug)]
struct ClaudeSpec {
    event: String,
    matcher: String,
    script: String,
}

pub fn settings_check(args: &[String]) -> SetupResult<()> {
    if args.len() != 3 {
        return Err("Usage: vibeguard-runtime setup-settings-check <repo-dir> <settings-file> <pre-hooks|post-hooks|full-hooks|profile-hooks:<profile>>".into());
    }
    let repo_dir = Path::new(&args[0]);
    let data = Value::Object(read_json_object(Path::new(&args[1]), false)?);
    let ok = match args[2].as_str() {
        "pre-hooks" => settings_has_pre_hooks(repo_dir, &data)?,
        "post-hooks" => settings_has_post_hooks(repo_dir, &data)?,
        "full-hooks" => settings_has_full_hooks(repo_dir, &data)?,
        target if target.starts_with("profile-hooks:") => {
            let profile = &target["profile-hooks:".len()..];
            if !matches!(profile, "minimal" | "core" | "full" | "strict") {
                return Err(format!("unsupported profile target: {profile}").into());
            }
            settings_has_profile_hooks(repo_dir, &data, profile)?
        }
        _ => false,
    };
    if ok {
        Ok(())
    } else {
        std::process::exit(1);
    }
}

pub fn settings_check_supports_profile_hooks(_args: &[String]) -> SetupResult<()> {
    Ok(())
}

pub fn settings_upsert(args: &[String]) -> SetupResult<()> {
    if args.len() < 3 {
        return Err("Usage: vibeguard-runtime setup-settings-upsert <repo-dir> <settings-file> <profile> [--dry-run] [--force-overwrite]".into());
    }
    let repo_dir = Path::new(&args[0]);
    let settings_path = Path::new(&args[1]);
    let profile = &args[2];
    let dry_run = args.iter().any(|arg| arg == "--dry-run");
    let force = args.iter().any(|arg| arg == "--force-overwrite");
    let before_text = std::fs::read_to_string(settings_path).unwrap_or_default();
    let mut data = Value::Object(read_json_object(settings_path, true)?);
    let mut changed = false;
    changed |= settings_remove_stale_installed(&mut data);
    if data.get("hooks").and_then(Value::as_object).is_none() {
        data.as_object_mut()
            .expect("object")
            .insert("hooks".to_string(), json!({}));
        changed = true;
    }
    let desired = claude_specs(repo_dir, Some(profile))?;
    for spec in &desired {
        changed |= settings_upsert_hook(&mut data, spec, force);
    }
    let desired_identities: BTreeSet<(String, String, String)> =
        desired.iter().map(settings_spec_identity).collect();
    changed |= settings_remove_unprofiled_hooks(repo_dir, &mut data, &desired_identities)?;
    if dry_run {
        if changed {
            let after = serde_json::to_string_pretty(&data)? + "\n";
            print!(
                "{}",
                simple_unified_diff(settings_path, &before_text, &after)
            );
            println!("CHANGED");
        } else {
            println!("SKIP");
        }
        return Ok(());
    }
    if changed {
        write_json_atomic(settings_path, &data)?;
        println!("CHANGED");
    } else {
        println!("SKIP");
    }
    Ok(())
}

pub fn settings_remove(args: &[String]) -> SetupResult<()> {
    if args.len() != 2 {
        return Err(
            "Usage: vibeguard-runtime setup-settings-remove <repo-dir> <settings-file>".into(),
        );
    }
    let settings_path = Path::new(&args[1]);
    if !settings_path.exists() {
        println!("SKIP");
        return Ok(());
    }
    let repo_dir = Path::new(&args[0]);
    let mut data = Value::Object(read_json_object(settings_path, false)?);
    let before = serde_json::to_string(&data)?;
    for script in claude_managed_scripts(repo_dir)? {
        for event in [
            "PreToolUse",
            "PostToolUse",
            "Stop",
            "SessionStart",
            "PreCompact",
            "UserPromptSubmit",
        ] {
            settings_remove_hook(&mut data, event, &script);
        }
    }
    if serde_json::to_string(&data)? == before {
        println!("SKIP");
    } else {
        write_json_atomic(settings_path, &data)?;
        println!("CHANGED");
    }
    Ok(())
}

pub fn settings_check_stale(args: &[String]) -> SetupResult<()> {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime setup-settings-check-stale <settings-file>".into());
    }
    let settings_path = Path::new(&args[0]);
    if !settings_path.exists() {
        return Ok(());
    }
    let data = Value::Object(read_json_object(settings_path, false)?);
    let findings = settings_stale_findings(&data, settings_path);
    for finding in &findings {
        println!("{finding}");
    }
    if !findings.is_empty() {
        std::process::exit(1);
    }
    Ok(())
}

fn claude_specs(repo_dir: &Path, profile: Option<&str>) -> SetupResult<Vec<ClaudeSpec>> {
    let text = std::fs::read_to_string(repo_dir.join("hooks/manifest.json"))?;
    let manifest: Value = serde_json::from_str(&text)?;
    let hooks = manifest
        .get("hooks")
        .and_then(Value::as_array)
        .ok_or("hooks manifest must contain a hooks array")?;
    let mut specs = Vec::new();
    for item in hooks {
        let item = item
            .as_object()
            .ok_or("each hook manifest entry must be an object")?;
        let Some(claude) = item.get("claude").and_then(Value::as_object) else {
            continue;
        };
        if claude.get("enabled").and_then(Value::as_bool) != Some(true) {
            continue;
        }
        let profiles = claude
            .get("profiles")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if let Some(profile) = profile
            && !profiles.iter().any(|value| value.as_str() == Some(profile))
        {
            continue;
        }
        let matchers = claude
            .get("matchers")
            .and_then(Value::as_array)
            .ok_or("claude.matchers must be an array")?;
        for matcher in matchers {
            specs.push(ClaudeSpec {
                event: claude
                    .get("event")
                    .and_then(Value::as_str)
                    .ok_or("claude.event missing")?
                    .to_string(),
                matcher: matcher.as_str().unwrap_or("").to_string(),
                script: item
                    .get("script")
                    .and_then(Value::as_str)
                    .ok_or("hook script missing")?
                    .to_string(),
            });
        }
    }
    Ok(specs)
}

fn settings_has_pre_hooks(repo_dir: &Path, data: &Value) -> SetupResult<bool> {
    Ok(claude_specs(repo_dir, Some("minimal"))?
        .iter()
        .filter(|spec| spec.event == "PreToolUse")
        .all(|spec| settings_has_spec(data, spec)))
}

fn settings_has_post_hooks(repo_dir: &Path, data: &Value) -> SetupResult<bool> {
    Ok(claude_specs(repo_dir, Some("minimal"))?
        .iter()
        .filter(|spec| spec.event == "PostToolUse")
        .all(|spec| settings_has_spec(data, spec)))
}

fn settings_has_full_hooks(repo_dir: &Path, data: &Value) -> SetupResult<bool> {
    let core_scripts: BTreeSet<String> = claude_specs(repo_dir, Some("core"))?
        .into_iter()
        .map(|spec| spec.script)
        .collect();
    Ok(settings_has_post_hooks(repo_dir, data)?
        && claude_specs(repo_dir, Some("full"))?
            .iter()
            .filter(|spec| !core_scripts.contains(&spec.script))
            .all(|spec| settings_has_spec(data, spec)))
}

fn settings_has_profile_hooks(repo_dir: &Path, data: &Value, profile: &str) -> SetupResult<bool> {
    let desired = claude_specs(repo_dir, Some(profile))?;
    if !desired.iter().all(|spec| settings_has_spec(data, spec)) {
        return Ok(false);
    }
    let desired_identities: BTreeSet<(String, String, String)> =
        desired.iter().map(settings_spec_identity).collect();
    let managed_counts = settings_managed_hook_identity_counts(repo_dir, data)?;
    Ok(managed_counts
        .keys()
        .all(|identity| desired_identities.contains(identity))
        && managed_counts.values().all(|count| *count == 1))
}

fn settings_has_spec(data: &Value, spec: &ClaudeSpec) -> bool {
    let Some(entries) = data
        .get("hooks")
        .and_then(Value::as_object)
        .and_then(|hooks| hooks.get(&spec.event))
        .and_then(Value::as_array)
    else {
        return false;
    };
    entries.iter().any(|entry| {
        let matcher = entry.get("matcher").and_then(Value::as_str).unwrap_or("");
        if matcher != spec.matcher {
            return false;
        }
        settings_entry_has_script(entry, &spec.script)
    })
}

fn settings_upsert_hook(data: &mut Value, spec: &ClaudeSpec, force: bool) -> bool {
    let wrapper = home_dir()
        .unwrap_or_default()
        .join(".vibeguard")
        .join("run-hook.sh");
    let desired = format!(
        "bash {} {}",
        shell_quote(&wrapper.display().to_string()),
        shell_quote(&spec.script)
    );
    let hooks = data["hooks"].as_object_mut().expect("hooks object");
    let entries = hooks.entry(spec.event.clone()).or_insert_with(|| json!([]));
    if !entries.is_array() {
        *entries = json!([]);
    }
    let entries = entries.as_array_mut().expect("entries array");
    let mut changed = false;
    let mut found = false;
    for entry in entries.iter_mut() {
        let matcher = entry.get("matcher").and_then(Value::as_str).unwrap_or("");
        if matcher != spec.matcher {
            continue;
        }
        let Some(hook_entries) = entry.get_mut("hooks").and_then(Value::as_array_mut) else {
            entry.as_object_mut().expect("entry object").insert(
                "hooks".to_string(),
                json!([{"type":"command","command":desired}]),
            );
            found = true;
            changed = true;
            continue;
        };
        for hook in hook_entries.iter_mut() {
            if !settings_hook_is_script(hook, &spec.script) {
                continue;
            }
            found = true;
            if hook.get("type").and_then(Value::as_str) != Some("command") {
                hook.as_object_mut()
                    .expect("hook object")
                    .insert("type".to_string(), Value::String("command".to_string()));
                changed = true;
            }
            let command = hook.get("command").and_then(Value::as_str).unwrap_or("");
            if command != desired {
                if force || settings_is_canonical(command, &spec.script) {
                    hook.as_object_mut()
                        .expect("hook object")
                        .insert("command".to_string(), Value::String(desired.clone()));
                    changed = true;
                } else {
                    eprintln!(
                        "WARN: preserving customized VibeGuard hook command for {}; use --force-overwrite to replace it",
                        spec.script
                    );
                }
            }
        }
    }
    if !found {
        let mut entry = json!({"hooks":[{"type":"command","command":desired}]});
        if !spec.matcher.is_empty() {
            entry
                .as_object_mut()
                .expect("entry object")
                .insert("matcher".to_string(), Value::String(spec.matcher.clone()));
        }
        entries.push(entry);
        changed = true;
    }
    changed
}

fn settings_remove_hook(data: &mut Value, event: &str, script: &str) -> bool {
    let Some(entries) = data
        .get_mut("hooks")
        .and_then(Value::as_object_mut)
        .and_then(|hooks| hooks.get_mut(event))
        .and_then(Value::as_array_mut)
    else {
        return false;
    };
    let mut changed = false;
    for entry in entries.iter_mut() {
        let Some(hook_entries) = entry.get_mut("hooks").and_then(Value::as_array_mut) else {
            continue;
        };
        let before = hook_entries.len();
        hook_entries.retain(|hook| !settings_hook_is_script(hook, script));
        changed |= before != hook_entries.len();
    }
    let before = entries.len();
    entries.retain(|entry| {
        entry
            .get("hooks")
            .and_then(Value::as_array)
            .is_none_or(|hooks| !hooks.is_empty())
    });
    changed | (before != entries.len())
}

fn settings_remove_unprofiled_hooks(
    repo_dir: &Path,
    data: &mut Value,
    desired: &BTreeSet<(String, String, String)>,
) -> SetupResult<bool> {
    let managed_scripts = claude_managed_scripts(repo_dir)?;
    let Some(hooks) = data.get_mut("hooks").and_then(Value::as_object_mut) else {
        return Ok(false);
    };
    let mut changed = false;
    let mut seen_profile_identities = BTreeSet::new();
    for (event, entries) in hooks.iter_mut() {
        let Some(entries) = entries.as_array_mut() else {
            continue;
        };
        for entry in entries.iter_mut() {
            let matcher = entry
                .get("matcher")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let Some(hook_entries) = entry.get_mut("hooks").and_then(Value::as_array_mut) else {
                continue;
            };
            let before = hook_entries.len();
            hook_entries.retain(|hook| {
                settings_hook_managed_script(hook, &managed_scripts).is_none_or(|script| {
                    let identity = (event.clone(), matcher.clone(), script.to_string());
                    desired.contains(&identity) && seen_profile_identities.insert(identity)
                })
            });
            changed |= before != hook_entries.len();
        }
        let before = entries.len();
        entries.retain(|entry| {
            entry
                .get("hooks")
                .and_then(Value::as_array)
                .is_none_or(|hooks| !hooks.is_empty())
        });
        changed |= before != entries.len();
    }
    Ok(changed)
}

fn settings_remove_stale_installed(data: &mut Value) -> bool {
    let Some(hooks) = data.get_mut("hooks").and_then(Value::as_object_mut) else {
        return false;
    };
    let mut changed = false;
    for entries in hooks.values_mut() {
        let Some(entries) = entries.as_array_mut() else {
            continue;
        };
        for entry in entries.iter_mut() {
            let Some(hook_entries) = entry.get_mut("hooks").and_then(Value::as_array_mut) else {
                continue;
            };
            let before = hook_entries.len();
            hook_entries.retain(|hook| {
                let command = hook.get("command").and_then(Value::as_str).unwrap_or("");
                settings_direct_installed_hook_target(command).is_none()
                    && settings_hook_target(command, "run-hook.sh")
                        .is_none_or(|target| target.exists())
            });
            changed |= before != hook_entries.len();
        }
    }
    changed
}

fn claude_managed_scripts(repo_dir: &Path) -> SetupResult<BTreeSet<String>> {
    Ok(claude_specs(repo_dir, None)?
        .into_iter()
        .map(|spec| spec.script)
        .collect())
}

fn settings_spec_identity(spec: &ClaudeSpec) -> (String, String, String) {
    (
        spec.event.clone(),
        spec.matcher.clone(),
        spec.script.clone(),
    )
}

fn settings_managed_hook_identity_counts(
    repo_dir: &Path,
    data: &Value,
) -> SetupResult<BTreeMap<(String, String, String), usize>> {
    let managed_scripts = claude_managed_scripts(repo_dir)?;
    let mut counts = BTreeMap::new();
    let Some(hooks) = data.get("hooks").and_then(Value::as_object) else {
        return Ok(counts);
    };
    for (event, entries) in hooks {
        let Some(entries) = entries.as_array() else {
            continue;
        };
        for entry in entries {
            let matcher = entry.get("matcher").and_then(Value::as_str).unwrap_or("");
            let Some(hook_entries) = entry.get("hooks").and_then(Value::as_array) else {
                continue;
            };
            for hook in hook_entries {
                if let Some(script) = settings_hook_managed_script(hook, &managed_scripts) {
                    *counts
                        .entry((event.clone(), matcher.to_string(), script.to_string()))
                        .or_insert(0) += 1;
                }
            }
        }
    }
    Ok(counts)
}

fn settings_entry_has_script(entry: &Value, script: &str) -> bool {
    entry
        .get("hooks")
        .and_then(Value::as_array)
        .is_some_and(|hooks| {
            hooks
                .iter()
                .any(|hook| settings_hook_is_script(hook, script))
        })
}

fn settings_hook_is_script(hook: &Value, script: &str) -> bool {
    hook.get("command")
        .and_then(Value::as_str)
        .is_some_and(|command| hook_identity::command_invokes_script(command, script))
}

fn settings_hook_managed_script<'a>(
    hook: &Value,
    managed_scripts: &'a BTreeSet<String>,
) -> Option<&'a str> {
    hook.get("command")
        .and_then(Value::as_str)
        .and_then(|command| hook_identity::managed_script_from_command(command, managed_scripts))
}

fn settings_is_canonical(command: &str, script: &str) -> bool {
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

fn settings_stale_findings(data: &Value, config: &Path) -> Vec<String> {
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

fn settings_direct_installed_hook_target(command: &str) -> Option<PathBuf> {
    let home = home_dir()?;
    shell_split(command).into_iter().find_map(|token| {
        let path = settings_expand_path(&token, &home)?;
        path.to_string_lossy()
            .contains("/.vibeguard/installed/hooks/")
            .then_some(path)
    })
}

fn settings_hook_target(command: &str, wrapper_name: &str) -> Option<PathBuf> {
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

#[cfg(test)]
mod tests;
