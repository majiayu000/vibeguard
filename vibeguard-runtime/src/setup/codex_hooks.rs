use crate::setup::support::{
    SetupResult, basename, home_dir, read_json_object, shell_quote, shell_split, write_json_atomic,
};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

pub use crate::setup::codex_hooks_health::{
    codex_hooks_check_stale, codex_hooks_check_timeouts, codex_hooks_prune_stale_unmanaged,
};

#[derive(Clone, Debug, PartialEq, Eq)]
struct CodexSpec {
    event: String,
    matcher: Option<String>,
    script: String,
    timeout: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct CodexEntryRecord {
    event: String,
    matcher: Option<String>,
    command: String,
    timeout: Option<i64>,
}

struct CodexManifestData {
    specs: Vec<CodexSpec>,
    managed_scripts: BTreeSet<String>,
    script_targets: BTreeMap<String, String>,
}

const CODEX_EVENTS: &[&str] = &[
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "Stop",
    "SessionStart",
    "PreCompact",
    "PostCompact",
    "UserPromptSubmit",
];
const PROFILES: &[&str] = &["minimal", "core", "full", "strict"];
const DEFAULT_PROFILE: &str = "core";

pub fn codex_hooks_upsert(args: &[String]) -> SetupResult<()> {
    if args.len() != 3 && args.len() != 4 {
        return Err(
            "Usage: vibeguard-runtime setup-codex-hooks-upsert <repo-dir> <hooks-file> <wrapper> [profile]"
                .into(),
        );
    }
    let repo_dir = Path::new(&args[0]);
    let hooks_path = Path::new(&args[1]);
    let wrapper = &args[2];
    let profile = codex_profile_arg(args.get(3).map(String::as_str))?;
    let manifest = codex_manifest_data_for_profile(repo_dir, Some(profile))?;
    let mut data = Value::Object(read_json_object(hooks_path, true)?);
    let before = serde_json::to_string(&data)?;
    ensure_hooks_root(&mut data)?;
    codex_prune_managed(&mut data, &manifest.managed_scripts);
    codex_prune_stale(&mut data, &manifest.script_targets);
    ensure_hooks_root(&mut data)?;
    let hooks = data["hooks"]
        .as_object_mut()
        .ok_or("hooks.json hooks must be an object")?;
    for spec in manifest.specs {
        let entries = hooks.entry(spec.event.clone()).or_insert_with(|| json!([]));
        if !entries.is_array() {
            *entries = json!([]);
        }
        let entries_arr = entries.as_array_mut().expect("entries are array");
        let command = codex_command(wrapper, &spec, profile);
        if !codex_has_entry(
            entries_arr,
            &manifest.managed_scripts,
            &command,
            spec.matcher.as_deref(),
            spec.timeout,
        ) {
            entries_arr.push(codex_build_entry(wrapper, &spec, profile));
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
    let managed_scripts = codex_managed_scripts(Path::new(&args[0]))?;
    let hooks_path = Path::new(&args[1]);
    if !hooks_path.exists() {
        println!("SKIP");
        return Ok(());
    }
    let mut data = Value::Object(read_json_object(hooks_path, false)?);
    let before = serde_json::to_string(&data)?;
    codex_prune_managed(&mut data, &managed_scripts);
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
    if args.len() != 3 && args.len() != 4 {
        return Err(
            "Usage: vibeguard-runtime setup-codex-hooks-check <repo-dir> <hooks-file> <wrapper> [profile]"
                .into(),
        );
    }
    let repo_dir = Path::new(&args[0]);
    let profile = codex_profile_arg(args.get(3).map(String::as_str))?;
    let manifest = codex_manifest_data_for_profile(repo_dir, Some(profile))?;
    let data = Value::Object(read_json_object(Path::new(&args[1]), false)?);
    let Some(hooks) = data.get("hooks").and_then(Value::as_object) else {
        std::process::exit(1);
    };
    let expected_records = codex_expected_records(&args[2], &manifest.specs, profile);
    for spec in &manifest.specs {
        let Some(entries) = hooks.get(&spec.event).and_then(Value::as_array) else {
            std::process::exit(1);
        };
        let command = codex_command(&args[2], spec, profile);
        if !codex_has_entry(
            entries,
            &manifest.managed_scripts,
            &command,
            spec.matcher.as_deref(),
            spec.timeout,
        ) {
            std::process::exit(1);
        }
    }
    if codex_has_unexpected_managed_entry(hooks, &manifest.managed_scripts, &expected_records) {
        std::process::exit(1);
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

pub fn profile_hook_scripts(args: &[String]) -> SetupResult<()> {
    if args.len() != 2 {
        return Err(
            "Usage: vibeguard-runtime setup-codex-profile-hook-scripts <repo-dir> <profile>".into(),
        );
    }
    let manifest = codex_manifest_data_for_profile(Path::new(&args[0]), Some(&args[1]))?;
    let mut scripts = BTreeSet::new();
    for spec in &manifest.specs {
        let source = manifest
            .script_targets
            .get(&spec.script)
            .ok_or_else(|| format!("Codex script target missing for {}", spec.script))?;
        scripts.insert(source);
    }
    for script in scripts {
        println!("{script}");
    }
    Ok(())
}

fn codex_manifest_data(repo_dir: &Path) -> SetupResult<CodexManifestData> {
    codex_manifest_data_for_profile(repo_dir, None)
}

fn codex_manifest_data_for_profile(
    repo_dir: &Path,
    profile: Option<&str>,
) -> SetupResult<CodexManifestData> {
    let manifest_path = repo_dir.join("hooks/manifest.json");
    let text = std::fs::read_to_string(&manifest_path).map_err(|error| {
        format!(
            "failed to read Codex hooks manifest {}: {error}",
            manifest_path.display()
        )
    })?;
    let manifest: Value = serde_json::from_str(&text).map_err(|error| {
        format!(
            "Codex hooks manifest {} contains invalid JSON: {error}",
            manifest_path.display()
        )
    })?;
    codex_manifest_value_for_profile(&manifest, profile).map_err(|error| {
        format!(
            "Codex hooks manifest {} is invalid: {error}",
            manifest_path.display()
        )
        .into()
    })
}

#[cfg(test)]
fn codex_manifest_value(manifest: &Value) -> SetupResult<CodexManifestData> {
    codex_manifest_value_for_profile(manifest, None)
}

fn codex_manifest_value_for_profile(
    manifest: &Value,
    profile: Option<&str>,
) -> SetupResult<CodexManifestData> {
    let selected_profile = profile.map(validate_codex_profile).transpose()?;
    if manifest.get("schema_version").and_then(Value::as_i64) != Some(1) {
        return Err("schema_version must be 1".into());
    }
    let profiles = manifest
        .get("profiles")
        .and_then(Value::as_array)
        .filter(|profiles| !profiles.is_empty())
        .ok_or("profiles must be a non-empty array")?;
    let mut seen_profiles = BTreeSet::new();
    for profile in profiles {
        let profile = profile
            .as_str()
            .filter(|profile| PROFILES.contains(profile))
            .ok_or("profiles contains an unknown or non-string value")?;
        if !seen_profiles.insert(profile) {
            return Err(format!("profiles contains duplicate value: {profile}").into());
        }
    }
    if let Some(profile) = selected_profile
        && !seen_profiles.contains(profile)
    {
        return Err(format!("profile {profile} is missing from manifest profiles").into());
    }
    let hooks = manifest
        .get("hooks")
        .and_then(Value::as_array)
        .filter(|hooks| !hooks.is_empty())
        .ok_or("hooks must be a non-empty array")?;
    let mut specs = Vec::new();
    let mut managed_scripts = BTreeSet::new();
    let mut script_targets = BTreeMap::new();
    for item in hooks {
        let Some(item_obj) = item.as_object() else {
            return Err("each hook manifest entry must be an object".into());
        };
        json_string(item_obj, "name")?;
        let script = json_string(item_obj, "script")?;
        validate_manifest_script(&script)?;
        json_string(item_obj, "kind")?;
        json_string(item_obj, "trigger")?;
        json_string(item_obj, "responsibilities")?;
        item_obj
            .get("decision_types")
            .and_then(Value::as_array)
            .ok_or("hook decision_types must be an array")?;
        item_obj
            .get("claude")
            .and_then(Value::as_object)
            .and_then(|claude| claude.get("enabled"))
            .and_then(Value::as_bool)
            .ok_or("hook claude.enabled must be boolean")?;
        managed_scripts.insert(script.clone());
        let codex = item_obj
            .get("codex")
            .and_then(Value::as_object)
            .ok_or("hook codex must be an object")?;
        let enabled = codex
            .get("enabled")
            .and_then(Value::as_bool)
            .ok_or("hook codex.enabled must be boolean")?;
        validate_codex_optional_fields(codex)?;
        if !enabled {
            continue;
        }
        let profile_allowed = if let Some(profile) = selected_profile {
            hook_profiles(item_obj)?
                .iter()
                .any(|candidate| candidate == profile)
        } else {
            true
        };
        let first_spec = specs.len();
        let mut item_specs = Vec::new();
        if let Some(entries_value) = codex.get("entries") {
            let entries = entries_value
                .as_array()
                .filter(|entries| !entries.is_empty())
                .ok_or("codex.entries must be a non-empty array")?;
            for entry in entries {
                let entry = entry
                    .as_object()
                    .ok_or("codex.entries must contain objects")?;
                item_specs.push(codex_spec(entry, Some(codex))?);
            }
        } else {
            item_specs.push(codex_spec(codex, None)?);
        }
        let expected_codex_script = format!("vibeguard-{script}");
        for spec in &item_specs {
            if spec.script != expected_codex_script {
                return Err(format!(
                    "Codex script must equal {expected_codex_script} for canonical script {script}"
                )
                .into());
            }
            managed_scripts.insert(spec.script.clone());
            script_targets.insert(spec.script.clone(), script.clone());
        }
        if profile_allowed {
            specs.extend(item_specs);
        }
        if first_spec == specs.len() {
            continue;
        }
    }
    Ok(CodexManifestData {
        specs,
        managed_scripts,
        script_targets,
    })
}

fn codex_spec(
    object: &serde_json::Map<String, Value>,
    fallback: Option<&serde_json::Map<String, Value>>,
) -> SetupResult<CodexSpec> {
    let event = json_string(object, "event")?;
    if !CODEX_EVENTS.contains(&event.as_str()) {
        return Err(format!("unsupported Codex event: {event}").into());
    }
    let script = object
        .get("script")
        .or_else(|| fallback.and_then(|value| value.get("script")))
        .and_then(Value::as_str)
        .ok_or("Codex script must be a string")?;
    validate_codex_script(script)?;
    let timeout = if object.contains_key("timeout") {
        positive_timeout(object)?
    } else {
        fallback.map(positive_timeout).transpose()?.flatten()
    };
    Ok(CodexSpec {
        event,
        matcher: nullable_matcher(object)?,
        script: script.to_string(),
        timeout,
    })
}

fn validate_codex_optional_fields(object: &serde_json::Map<String, Value>) -> SetupResult<()> {
    if object.contains_key("matcher") {
        nullable_matcher(object)?;
    }
    if let Some(event) = object.get("event") {
        let event = event.as_str().ok_or("Codex event must be a string")?;
        if !CODEX_EVENTS.contains(&event) {
            return Err(format!("unsupported Codex event: {event}").into());
        }
    }
    if let Some(script) = object.get("script") {
        validate_codex_script(script.as_str().ok_or("Codex script must be a string")?)?;
    }
    positive_timeout(object)?;
    Ok(())
}

fn validate_codex_profile(profile: &str) -> SetupResult<&str> {
    if PROFILES.contains(&profile) {
        Ok(profile)
    } else {
        Err(
            format!("unsupported Codex profile: {profile} (expected minimal|core|full|strict)")
                .into(),
        )
    }
}

fn codex_profile_arg(profile: Option<&str>) -> SetupResult<&str> {
    validate_codex_profile(profile.unwrap_or(DEFAULT_PROFILE))
}

fn hook_profiles(object: &serde_json::Map<String, Value>) -> SetupResult<Vec<String>> {
    let Some(profiles_value) = object
        .get("claude")
        .and_then(Value::as_object)
        .and_then(|claude| claude.get("profiles"))
    else {
        return Ok(PROFILES
            .iter()
            .map(|profile| (*profile).to_string())
            .collect());
    };
    let profiles = profiles_value
        .as_array()
        .filter(|profiles| !profiles.is_empty())
        .ok_or("hook claude.profiles must be a non-empty array")?;
    profiles
        .iter()
        .map(|profile| {
            let profile = profile
                .as_str()
                .ok_or("hook claude.profiles contains a non-string value")?;
            validate_codex_profile(profile)?;
            Ok(profile.to_string())
        })
        .collect()
}

fn nullable_matcher(object: &serde_json::Map<String, Value>) -> SetupResult<Option<String>> {
    match object.get("matcher") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err("Codex matcher must be a string or null".into()),
    }
}

fn positive_timeout(object: &serde_json::Map<String, Value>) -> SetupResult<Option<i64>> {
    match object.get("timeout") {
        None => Ok(None),
        Some(value) => value
            .as_i64()
            .filter(|timeout| *timeout > 0)
            .map(Some)
            .ok_or_else(|| "Codex timeout must be a positive integer".into()),
    }
}

fn validate_codex_script(script: &str) -> SetupResult<()> {
    let valid = script
        .strip_prefix("vibeguard-")
        .and_then(|value| value.strip_suffix(".sh"))
        .is_some_and(|value| {
            !value.is_empty()
                && value
                    .chars()
                    .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '-')
        });
    if !valid {
        return Err("Codex script must be a namespaced vibeguard-*.sh script".into());
    }
    Ok(())
}

fn validate_manifest_script(script: &str) -> SetupResult<()> {
    let path = script.strip_suffix(".sh").unwrap_or(script);
    let valid = !path.is_empty()
        && path
            .chars()
            .next()
            .is_some_and(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit())
        && path.chars().all(|ch| {
            ch.is_ascii_lowercase() || ch.is_ascii_digit() || matches!(ch, '_' | '/' | '-')
        })
        && path.split('/').all(|segment| !segment.is_empty());
    if !valid {
        return Err("hook script must be a safe hooks-relative path".into());
    }
    Ok(())
}

fn json_string(object: &serde_json::Map<String, Value>, key: &str) -> SetupResult<String> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
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

fn codex_prune_managed(data: &mut Value, managed_scripts: &BTreeSet<String>) {
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
                    !codex_command_is_managed(managed_scripts, command)
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

fn codex_prune_stale(data: &mut Value, script_targets: &BTreeMap<String, String>) {
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
                        && codex_hook_target(command, script_targets)
                            .is_none_or(|target| target.exists())
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

fn codex_command(wrapper: &str, spec: &CodexSpec, profile: &str) -> String {
    format!(
        "env VIBEGUARD_PROFILE=\"${{VIBEGUARD_PROFILE:-{}}}\" bash {} {}",
        profile,
        shell_quote(wrapper),
        spec.script
    )
}

fn codex_build_entry(wrapper: &str, spec: &CodexSpec, profile: &str) -> Value {
    let mut hook = serde_json::Map::new();
    hook.insert("type".to_string(), Value::String("command".to_string()));
    hook.insert(
        "command".to_string(),
        Value::String(codex_command(wrapper, spec, profile)),
    );
    if let Some(timeout) = spec.timeout {
        hook.insert("timeout".to_string(), Value::Number(timeout.into()));
    }
    let mut entry = serde_json::Map::new();
    entry.insert("hooks".to_string(), Value::Array(vec![Value::Object(hook)]));
    if let Some(matcher) = &spec.matcher
        && !matcher.is_empty()
    {
        entry.insert("matcher".to_string(), Value::String(matcher.clone()));
    }
    Value::Object(entry)
}

fn codex_expected_records(
    wrapper: &str,
    specs: &[CodexSpec],
    profile: &str,
) -> BTreeSet<CodexEntryRecord> {
    specs
        .iter()
        .map(|spec| CodexEntryRecord {
            event: spec.event.clone(),
            matcher: spec.matcher.clone(),
            command: codex_command(wrapper, spec, profile),
            timeout: spec.timeout,
        })
        .collect()
}

fn codex_has_unexpected_managed_entry(
    hooks: &serde_json::Map<String, Value>,
    managed_scripts: &BTreeSet<String>,
    expected_records: &BTreeSet<CodexEntryRecord>,
) -> bool {
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
                .map(str::to_string);
            let Some(hook_entries) = entry_obj.get("hooks").and_then(Value::as_array) else {
                continue;
            };
            for hook in hook_entries {
                let command = hook.get("command").and_then(Value::as_str).unwrap_or("");
                if !codex_command_is_managed(managed_scripts, command) {
                    continue;
                }
                let record = CodexEntryRecord {
                    event: event.clone(),
                    matcher: matcher.clone(),
                    command: command.to_string(),
                    timeout: hook.get("timeout").and_then(Value::as_i64),
                };
                if !expected_records.contains(&record) {
                    return true;
                }
            }
        }
    }
    false
}

fn codex_has_entry(
    entries: &[Value],
    managed_scripts: &BTreeSet<String>,
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
            codex_command_is_managed(managed_scripts, hook_command)
                && hook_command == command
                && hook.get("type").and_then(Value::as_str) == Some("command")
                && match timeout {
                    Some(expected) => hook.get("timeout").and_then(Value::as_i64) == Some(expected),
                    None => hook.get("timeout").is_none(),
                }
        })
    })
}

pub(crate) fn codex_command_is_managed(managed_scripts: &BTreeSet<String>, command: &str) -> bool {
    let parts = shell_split(command);
    for (idx, token) in parts.iter().enumerate() {
        if basename(token) == "run-hook-codex.sh"
            && let Some(next) = parts.get(idx + 1)
            && managed_scripts.contains(basename(next))
        {
            return true;
        }
        let base = basename(token);
        if managed_scripts.contains(base) {
            return true;
        }
    }
    false
}

pub(crate) fn codex_managed_scripts(repo_dir: &Path) -> SetupResult<BTreeSet<String>> {
    Ok(codex_manifest_data(repo_dir)?.managed_scripts)
}

pub(crate) fn codex_managed_script_contract(
    repo_dir: &Path,
) -> SetupResult<(BTreeSet<String>, BTreeMap<String, String>)> {
    let manifest = codex_manifest_data(repo_dir)?;
    Ok((manifest.managed_scripts, manifest.script_targets))
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

fn codex_hook_target(command: &str, script_targets: &BTreeMap<String, String>) -> Option<PathBuf> {
    let home = home_dir()?;
    let parts = shell_split(command);
    for (idx, token) in parts.iter().enumerate() {
        let Some(path) = codex_expand_path(token, &home) else {
            continue;
        };
        if path
            .to_string_lossy()
            .ends_with("/.vibeguard/run-hook-codex.sh")
        {
            let script = parts.get(idx + 1)?;
            if !script.contains('/') {
                let canonical_script = script_targets.get(script).unwrap_or(script);
                let installed = path
                    .parent()?
                    .join("installed/hooks")
                    .join(canonical_script);
                if installed.parent().is_some_and(Path::exists) {
                    return Some(installed);
                }
            }
        }
    }
    None
}

pub(crate) fn codex_expand_path(token: &str, home: &Path) -> Option<PathBuf> {
    token
        .strip_prefix("~/")
        .map(|tail| home.join(tail))
        .or_else(|| token.strip_prefix("$HOME/").map(|tail| home.join(tail)))
        .or_else(|| token.strip_prefix("${HOME}/").map(|tail| home.join(tail)))
        .or_else(|| token.starts_with('/').then(|| PathBuf::from(token)))
}

#[cfg(test)]
mod tests;
