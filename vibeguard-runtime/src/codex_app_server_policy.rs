use serde_json::Value;
use std::collections::HashMap;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use crate::git_root::git_root_for;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookPolicyDecision {
    Run {
        warn_mode: bool,
        reason: Option<String>,
    },
    Skip(String),
    Error(String),
}

pub fn evaluate_hook_policy(
    hook_name: &str,
    cwd: Option<&str>,
    env_overrides: &HashMap<String, String>,
) -> HookPolicyDecision {
    let Some(path) = project_config_path(cwd, env_overrides) else {
        return HookPolicyDecision::Run {
            warn_mode: false,
            reason: None,
        };
    };

    let config = match load_project_config(&path) {
        Ok(config) => config,
        Err(reason) => return HookPolicyDecision::Error(reason),
    };

    let canonical_hook = app_server_canonical_hook_name(hook_name);
    let enforcement = config.enforcement.as_deref().unwrap_or("block");
    if enforcement == "off" {
        return HookPolicyDecision::Skip("VibeGuard policy skip: enforcement=off".into());
    }

    if config
        .disabled_hooks
        .iter()
        .any(|hook| hook == &canonical_hook)
    {
        return HookPolicyDecision::Skip(format!(
            "VibeGuard policy skip: disabled_hooks contains {canonical_hook}"
        ));
    }

    let profile = config.profile.as_deref().unwrap_or("core");
    if !profile_allows_hook(profile, &canonical_hook) {
        return HookPolicyDecision::Skip(format!(
            "VibeGuard policy skip: profile={profile} excludes {canonical_hook}"
        ));
    }

    if enforcement == "warn" {
        return HookPolicyDecision::Run {
            warn_mode: true,
            reason: Some("VibeGuard policy warn: enforcement=warn".into()),
        };
    }

    HookPolicyDecision::Run {
        warn_mode: false,
        reason: None,
    }
}

pub fn required_hook_missing_message(hook_name: &str, hook_path: &Path) -> Option<String> {
    if matches!(
        app_server_canonical_hook_name(hook_name).as_str(),
        "pre-bash-guard" | "pre-edit-guard" | "pre-write-guard"
    ) {
        return Some(format!(
            "VIBEGUARD install incomplete: missing required hook {hook_name} at {}",
            hook_path.display()
        ));
    }
    None
}

fn project_config_path(
    cwd: Option<&str>,
    env_overrides: &HashMap<String, String>,
) -> Option<PathBuf> {
    if let Some(configured) = env_value("VIBEGUARD_PROJECT_CONFIG", env_overrides) {
        let path = PathBuf::from(configured);
        return path.is_file().then_some(path);
    }

    let cwd_path = cwd
        .filter(|text| !text.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok())?;

    if let Some(git_root) = git_root_for(&cwd_path) {
        let candidate = git_root.join(".vibeguard.json");
        if candidate.is_file() {
            return Some(candidate);
        }
    }

    let candidate = cwd_path.join(".vibeguard.json");
    candidate.is_file().then_some(candidate)
}

fn env_value(name: &str, env_overrides: &HashMap<String, String>) -> Option<String> {
    env_overrides
        .get(name)
        .filter(|value| !value.is_empty())
        .cloned()
        .or_else(|| std::env::var(name).ok().filter(|value| !value.is_empty()))
}

struct ProjectConfig {
    enforcement: Option<String>,
    profile: Option<String>,
    disabled_hooks: Vec<String>,
}

fn load_project_config(path: &Path) -> Result<ProjectConfig, String> {
    let text = std::fs::read_to_string(path).map_err(|err| {
        if err.kind() == ErrorKind::InvalidData {
            format!(
                "VibeGuard project config invalid UTF-8: {}: {err}",
                path.display()
            )
        } else {
            format!(
                "VibeGuard project config cannot be read: {}: {err}",
                path.display()
            )
        }
    })?;
    let value = serde_json::from_str::<Value>(&text).map_err(|err| {
        format!(
            "VibeGuard project config invalid JSON: {}: {err}",
            path.display()
        )
    })?;
    let object = value.as_object().ok_or_else(|| {
        format!(
            "VibeGuard project config invalid: {} must be a JSON object",
            path.display()
        )
    })?;

    validate_known_properties(path, object)?;
    let enforcement = optional_enum(path, object, "enforcement", &["block", "warn", "off"])?;
    let profile = optional_enum(
        path,
        object,
        "profile",
        &["minimal", "core", "full", "strict"],
    )?;
    let disabled_hooks = optional_string_array(path, object, "disabled_hooks")?;
    validate_disabled_hooks(path, &disabled_hooks)?;
    validate_string_enum_array(
        path,
        object,
        "languages",
        &["rust", "python", "go", "typescript", "javascript"],
    )?;
    validate_disabled_rules(path, object)?;
    validate_string_enum_array(
        path,
        object,
        "disabled_guards",
        &[
            "check_any_abuse",
            "check_circular_deps",
            "check_code_slop",
            "check_component_duplication",
            "check_console_residual",
            "check_dead_shims",
            "check_declaration_execution_gap",
            "check_defer_in_loop",
            "check_dependency_layers",
            "check_duplicate_constants",
            "check_duplicate_types",
            "check_duplicates",
            "check_error_handling",
            "check_goroutine_leak",
            "check_naming_convention",
            "check_nested_locks",
            "check_semantic_effect",
            "check_single_source_of_truth",
            "check_taste_invariants",
            "check_test_integrity",
            "check_unwrap_in_prod",
            "check_workspace_consistency",
        ],
    )?;
    validate_gc_config(path, object)?;

    Ok(ProjectConfig {
        enforcement,
        profile,
        disabled_hooks,
    })
}

fn validate_known_properties(
    path: &Path,
    object: &serde_json::Map<String, Value>,
) -> Result<(), String> {
    for key in object.keys() {
        if !matches!(
            key.as_str(),
            "profile"
                | "enforcement"
                | "languages"
                | "disabled_hooks"
                | "disabled_rules"
                | "disabled_guards"
                | "gc"
        ) {
            return Err(format!(
                "VibeGuard project config invalid: {} contains unknown field {key}",
                path.display()
            ));
        }
    }
    Ok(())
}

fn optional_enum(
    path: &Path,
    object: &serde_json::Map<String, Value>,
    field: &str,
    allowed: &[&str],
) -> Result<Option<String>, String> {
    let Some(value) = object.get(field) else {
        return Ok(None);
    };
    let Some(text) = value.as_str() else {
        return Err(format!(
            "VibeGuard project config invalid: {} field {field} must be a string",
            path.display()
        ));
    };
    if allowed.iter().any(|allowed| allowed == &text) {
        Ok(Some(text.to_string()))
    } else {
        Err(format!(
            "VibeGuard project config invalid: {} field {field} has unsupported value {text}",
            path.display()
        ))
    }
}

fn optional_string_array(
    path: &Path,
    object: &serde_json::Map<String, Value>,
    field: &str,
) -> Result<Vec<String>, String> {
    let Some(value) = object.get(field) else {
        return Ok(Vec::new());
    };
    let Some(items) = value.as_array() else {
        return Err(format!(
            "VibeGuard project config invalid: {} field {field} must be an array",
            path.display()
        ));
    };

    items
        .iter()
        .map(|item| {
            item.as_str().map(str::to_string).ok_or_else(|| {
                format!(
                    "VibeGuard project config invalid: {} field {field} must contain only strings",
                    path.display()
                )
            })
        })
        .collect()
}

fn validate_disabled_hooks(path: &Path, hooks: &[String]) -> Result<(), String> {
    for hook in hooks {
        if !matches!(
            hook.as_str(),
            "analysis-paralysis-guard"
                | "count-active-constraints"
                | "learn-evaluator"
                | "post-build-check"
                | "post-edit-guard"
                | "post-write-guard"
                | "pre-bash-guard"
                | "pre-commit-guard"
                | "pre-edit-guard"
                | "pre-write-guard"
                | "stop-guard"
        ) {
            return Err(format!(
                "VibeGuard project config invalid: {} disabled_hooks contains unsupported hook {hook}",
                path.display()
            ));
        }
    }
    Ok(())
}

fn validate_string_enum_array(
    path: &Path,
    object: &serde_json::Map<String, Value>,
    field: &str,
    allowed: &[&str],
) -> Result<(), String> {
    let values = optional_string_array(path, object, field)?;
    for (index, value) in values.iter().enumerate() {
        if !allowed.iter().any(|allowed| allowed == &value.as_str()) {
            return Err(format!(
                "VibeGuard project config invalid: {} .{field}.{index}: unsupported value {value}",
                path.display()
            ));
        }
    }
    Ok(())
}

fn validate_disabled_rules(
    path: &Path,
    object: &serde_json::Map<String, Value>,
) -> Result<(), String> {
    let rules = optional_string_array(path, object, "disabled_rules")?;
    for (index, rule) in rules.iter().enumerate() {
        if !valid_disabled_rule_id(rule) {
            return Err(format!(
                "VibeGuard project config invalid: {} .disabled_rules.{index}: unsupported rule id {rule}",
                path.display()
            ));
        }
    }
    Ok(())
}

fn valid_disabled_rule_id(rule: &str) -> bool {
    let Some((prefix, suffix)) = rule.split_once('-') else {
        return false;
    };
    if !matches!(
        prefix,
        "SEC" | "RS" | "GO" | "TS" | "PY" | "U" | "W" | "TASTE"
    ) {
        return false;
    }
    !suffix.is_empty()
        && suffix
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

fn validate_gc_config(path: &Path, object: &serde_json::Map<String, Value>) -> Result<(), String> {
    let Some(value) = object.get("gc") else {
        return Ok(());
    };
    let Some(gc) = value.as_object() else {
        return Err(format!(
            "VibeGuard project config invalid: {} .gc: expected object",
            path.display()
        ));
    };
    let allowed = [
        "log_threshold_mb",
        "archive_retain_months",
        "worktree_max_days",
        "session_metrics_retain_days",
        "learning_window_days",
        "gc_log_max_kb",
    ];
    for key in gc.keys() {
        if !allowed.iter().any(|allowed| allowed == &key.as_str()) {
            return Err(format!(
                "VibeGuard project config invalid: {} .gc.{key}: unknown property",
                path.display()
            ));
        }
    }
    for (key, value) in gc {
        let valid_positive_integer = match value.as_i64() {
            Some(number) => number >= 1,
            None => false,
        };
        if !valid_positive_integer {
            return Err(format!(
                "VibeGuard project config invalid: {} .gc.{key}: expected integer >= 1",
                path.display()
            ));
        }
    }
    Ok(())
}

fn app_server_canonical_hook_name(hook_name: &str) -> String {
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

fn profile_allows_hook(profile: &str, hook_name: &str) -> bool {
    match hook_name {
        "analysis-paralysis-guard" => matches!(profile, "core" | "full" | "strict"),
        "count-active-constraints" => profile == "strict",
        "post-build-check" | "stop-guard" | "learn-evaluator" => {
            matches!(profile, "full" | "strict")
        }
        _ => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_policy_dir(name: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "vibeguard_policy_{name}_{}_{}",
            std::process::id(),
            unique
        ));
        fs::create_dir_all(&root).expect("temp dir should be created");
        root
    }

    #[test]
    fn warn_mode_disabled_hook_policy_skips_canonical_name() {
        let repo = temp_policy_dir("disabled");
        fs::write(
            repo.join(".vibeguard.json"),
            r#"{"enforcement":"warn","disabled_hooks":["pre-bash-guard"]}"#,
        )
        .expect("project config should be written");

        let decision = evaluate_hook_policy(
            "vibeguard-pre-bash-guard.sh",
            repo.to_str(),
            &HashMap::new(),
        );

        assert!(
            matches!(decision, HookPolicyDecision::Skip(reason) if reason.contains("pre-bash-guard"))
        );
        let _ = fs::remove_dir_all(repo);
    }

    #[test]
    fn warn_enforcement_runs_in_warn_mode() {
        let repo = temp_policy_dir("warn");
        fs::write(repo.join(".vibeguard.json"), r#"{"enforcement":"warn"}"#)
            .expect("project config should be written");

        let decision = evaluate_hook_policy("pre-edit-guard.sh", repo.to_str(), &HashMap::new());

        assert!(matches!(
            decision,
            HookPolicyDecision::Run {
                warn_mode: true,
                ..
            }
        ));
        let _ = fs::remove_dir_all(repo);
    }

    #[test]
    fn minimal_profile_excludes_analysis_paralysis_guard() {
        let repo = temp_policy_dir("minimal_analysis");
        if let Err(err) = fs::write(repo.join(".vibeguard.json"), r#"{"profile":"minimal"}"#) {
            panic!("project config should be written: {err}");
        }

        let decision = evaluate_hook_policy(
            "analysis-paralysis-guard.sh",
            repo.to_str(),
            &HashMap::new(),
        );

        assert!(
            matches!(decision, HookPolicyDecision::Skip(reason) if reason.contains("profile=minimal excludes analysis-paralysis-guard"))
        );
        if let Err(err) = fs::remove_dir_all(&repo) {
            panic!("temp policy dir should be removed: {err}");
        }
    }

    #[test]
    fn core_profile_allows_analysis_paralysis_guard() {
        let repo = temp_policy_dir("core_analysis");
        if let Err(err) = fs::write(repo.join(".vibeguard.json"), r#"{"profile":"core"}"#) {
            panic!("project config should be written: {err}");
        }

        let decision = evaluate_hook_policy(
            "analysis-paralysis-guard.sh",
            repo.to_str(),
            &HashMap::new(),
        );

        assert!(matches!(
            decision,
            HookPolicyDecision::Run {
                warn_mode: false,
                ..
            }
        ));
        if let Err(err) = fs::remove_dir_all(&repo) {
            panic!("temp policy dir should be removed: {err}");
        }
    }

    #[test]
    fn omitted_profile_uses_core_default_for_full_only_hooks() {
        let repo = temp_policy_dir("default_core_profile");
        if let Err(err) = fs::write(repo.join(".vibeguard.json"), r#"{"enforcement":"block"}"#) {
            panic!("project config should be written: {err}");
        }

        let decision = evaluate_hook_policy("post-build-check.sh", repo.to_str(), &HashMap::new());

        assert!(
            matches!(decision, HookPolicyDecision::Skip(reason) if reason.contains("profile=core excludes post-build-check"))
        );
        if let Err(err) = fs::remove_dir_all(&repo) {
            panic!("temp policy dir should be removed: {err}");
        }
    }

    #[test]
    fn core_profile_excludes_strict_only_count_active_constraints() {
        let repo = temp_policy_dir("core_count_active_constraints");
        if let Err(err) = fs::write(repo.join(".vibeguard.json"), r#"{"profile":"core"}"#) {
            panic!("project config should be written: {err}");
        }

        let decision = evaluate_hook_policy(
            "count_active_constraints.sh",
            repo.to_str(),
            &HashMap::new(),
        );

        assert!(
            matches!(decision, HookPolicyDecision::Skip(reason) if reason.contains("profile=core excludes count-active-constraints"))
        );
        if let Err(err) = fs::remove_dir_all(&repo) {
            panic!("temp policy dir should be removed: {err}");
        }
    }

    #[test]
    fn malformed_allowed_project_config_fields_return_policy_error() {
        let cases = [
            (
                "bad_languages_type",
                r#"{"languages":[123]}"#,
                "field languages must contain only strings",
            ),
            (
                "bad_disabled_rule",
                r#"{"disabled_rules":["not-a-rule"]}"#,
                ".disabled_rules.0: unsupported rule id not-a-rule",
            ),
            (
                "bad_disabled_guard",
                r#"{"disabled_guards":["missing_guard"]}"#,
                ".disabled_guards.0: unsupported value missing_guard",
            ),
            ("bad_gc_type", r#"{"gc":"bad"}"#, ".gc: expected object"),
            (
                "bad_gc_threshold",
                r#"{"gc":{"log_threshold_mb":0}}"#,
                ".gc.log_threshold_mb: expected integer >= 1",
            ),
            (
                "bad_gc_key",
                r#"{"gc":{"unexpected_gc_key":1}}"#,
                ".gc.unexpected_gc_key: unknown property",
            ),
        ];

        for (name, config, expected) in cases {
            let repo = temp_policy_dir(name);
            if let Err(err) = fs::write(repo.join(".vibeguard.json"), config) {
                panic!("project config should be written: {err}");
            }

            let decision =
                evaluate_hook_policy("pre-edit-guard.sh", repo.to_str(), &HashMap::new());

            assert!(
                matches!(decision, HookPolicyDecision::Error(reason) if reason.contains(expected)),
                "expected policy error containing {expected}"
            );
            if let Err(err) = fs::remove_dir_all(&repo) {
                panic!("temp policy dir should be removed: {err}");
            }
        }
    }

    #[test]
    fn invalid_json_returns_policy_error() {
        let repo = temp_policy_dir("invalid");
        fs::write(repo.join(".vibeguard.json"), "{").expect("project config should be written");

        let decision = evaluate_hook_policy("pre-edit-guard.sh", repo.to_str(), &HashMap::new());

        assert!(
            matches!(decision, HookPolicyDecision::Error(reason) if reason.contains("invalid JSON"))
        );
        let _ = fs::remove_dir_all(repo);
    }

    #[test]
    fn unsupported_disabled_hook_returns_policy_error() {
        let repo = temp_policy_dir("unsupported_disabled_hook");
        fs::write(
            repo.join(".vibeguard.json"),
            r#"{"disabled_hooks":["missing-hook"]}"#,
        )
        .expect("project config should be written");

        let decision = evaluate_hook_policy("pre-edit-guard.sh", repo.to_str(), &HashMap::new());

        assert!(
            matches!(decision, HookPolicyDecision::Error(reason) if reason.contains("unsupported hook missing-hook"))
        );
        let _ = fs::remove_dir_all(repo);
    }
}
