use crate::HandlerResult;
use crate::git_root::git_root_for;
use serde_json::Value;
use std::collections::HashMap;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::process;

const PROFILE_VALUES: &[&str] = &["minimal", "core", "full", "strict"];
const ENFORCEMENT_VALUES: &[&str] = &["block", "warn", "off"];
const LANGUAGE_VALUES: &[&str] = &["rust", "python", "go", "typescript", "javascript"];
const HOOKS_MANIFEST_JSON: &str = include_str!("../../hooks/manifest.json");
const DISABLED_GUARD_VALUES: &[&str] = &[
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
];
const GC_KEYS: &[&str] = &[
    "log_threshold_mb",
    "archive_retain_months",
    "worktree_max_days",
    "session_metrics_retain_days",
    "learning_window_days",
    "gc_log_max_kb",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectConfig {
    pub enforcement: Option<String>,
    pub profile: Option<String>,
    pub disabled_hooks: Vec<String>,
}

pub fn project_config_path(
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

pub fn load_project_config(path: &Path) -> Result<ProjectConfig, String> {
    let value = read_project_config_json(path)?;
    validate_project_config_value(path, &value)?;
    let object = value
        .as_object()
        .ok_or_else(|| format_project_config_errors(path, &["$: expected object".to_string()]))?;

    Ok(ProjectConfig {
        enforcement: object
            .get("enforcement")
            .and_then(Value::as_str)
            .map(str::to_string),
        profile: object
            .get("profile")
            .and_then(Value::as_str)
            .map(str::to_string),
        disabled_hooks: object
            .get("disabled_hooks")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default(),
    })
}

pub fn project_config_validate(args: &[String]) -> HandlerResult {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime project-config-validate <config-file>".into());
    }
    match validate_project_config_file(Path::new(&args[0])) {
        Ok(()) => Ok(()),
        Err(message) => {
            eprintln!("{message}");
            process::exit(1);
        }
    }
}

pub fn project_config_value(args: &[String]) -> HandlerResult {
    if args.len() != 3 {
        return Err(
            "Usage: vibeguard-runtime project-config-value <config-file> <json-path> <default>"
                .into(),
        );
    }

    let path = Path::new(&args[0]);
    let key_path = &args[1];
    let default_value = &args[2];
    if !path.is_file() {
        println!("{default_value}");
        return Ok(());
    }

    let value = match validated_project_config_json(path) {
        Ok(value) => value,
        Err(message) => {
            eprintln!("{message}");
            process::exit(2);
        }
    };

    match value_at_path(&value, key_path) {
        Some(Value::String(text)) if !text.is_empty() => println!("{text}"),
        Some(Value::Number(number)) => println!("{number}"),
        Some(Value::Array(items)) => println!("{}", serde_json::to_string(items)?),
        Some(Value::Object(object)) => println!("{}", serde_json::to_string(object)?),
        _ => println!("{default_value}"),
    }
    Ok(())
}

fn validate_project_config_file(path: &Path) -> Result<(), String> {
    let value = read_project_config_json(path)?;
    validate_project_config_value(path, &value)
}

fn validated_project_config_json(path: &Path) -> Result<Value, String> {
    let value = read_project_config_json(path)?;
    validate_project_config_value(path, &value)?;
    Ok(value)
}

fn read_project_config_json(path: &Path) -> Result<Value, String> {
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
    serde_json::from_str::<Value>(&text).map_err(|err| {
        format!(
            "VibeGuard project config invalid JSON: {}: {err}",
            path.display()
        )
    })
}

fn validate_project_config_value(path: &Path, value: &Value) -> Result<(), String> {
    let Some(object) = value.as_object() else {
        return Err(format_project_config_errors(
            path,
            &["$: expected object".to_string()],
        ));
    };

    let mut errors = Vec::new();
    let disabled_hook_values = match disabled_hook_values() {
        Ok(values) => values,
        Err(error) => {
            errors.push(format!("disabled_hooks manifest error: {error}"));
            Vec::new()
        }
    };
    validate_known_properties(object, &mut errors);
    validate_optional_enum(object, "profile", PROFILE_VALUES, &mut errors);
    validate_optional_enum(object, "enforcement", ENFORCEMENT_VALUES, &mut errors);
    validate_string_array(object, "languages", Some(LANGUAGE_VALUES), &mut errors);
    validate_string_array_values(object, "disabled_hooks", &disabled_hook_values, &mut errors);
    validate_string_array(
        object,
        "disabled_guards",
        Some(DISABLED_GUARD_VALUES),
        &mut errors,
    );
    validate_disabled_rules(object, &mut errors);
    validate_gc(object, &mut errors);

    if errors.is_empty() {
        Ok(())
    } else {
        Err(format_project_config_errors(path, &errors))
    }
}

fn validate_known_properties(object: &serde_json::Map<String, Value>, errors: &mut Vec<String>) {
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
            errors.push(unknown_property_error(&[key.as_str()]));
        }
    }
}

fn validate_optional_enum(
    object: &serde_json::Map<String, Value>,
    field: &str,
    allowed: &[&str],
    errors: &mut Vec<String>,
) {
    let Some(value) = object.get(field) else {
        return;
    };
    let Some(text) = value.as_str() else {
        errors.push(format!(".{field}: expected string"));
        return;
    };
    if !allowed.iter().any(|allowed| allowed == &text) {
        errors.push(format!(
            ".{field}: unsupported value {text}; expected one of {}",
            allowed.join(", ")
        ));
    }
}

fn disabled_hook_values() -> Result<Vec<String>, String> {
    let manifest = serde_json::from_str::<Value>(HOOKS_MANIFEST_JSON)
        .map_err(|err| format!("hooks/manifest.json invalid JSON: {err}"))?;
    let hooks = manifest
        .get("hooks")
        .and_then(Value::as_array)
        .ok_or_else(|| "hooks/manifest.json missing hooks array".to_string())?;

    let mut names = Vec::new();
    for hook in hooks {
        let exposed = hook
            .get("config_exposure")
            .and_then(Value::as_object)
            .and_then(|config| config.get("disabled_hook"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if !exposed {
            continue;
        }
        let name = hook
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| "disabled hook entry missing string name".to_string())?;
        names.push(name.to_string());
    }

    names.sort();
    names.dedup();
    if names.is_empty() {
        return Err("hooks/manifest.json exposes no disabled hooks".to_string());
    }
    Ok(names)
}

fn validate_string_array(
    object: &serde_json::Map<String, Value>,
    field: &str,
    allowed: Option<&[&str]>,
    errors: &mut Vec<String>,
) {
    let Some(value) = object.get(field) else {
        return;
    };
    let Some(items) = value.as_array() else {
        errors.push(format!(".{field}: expected array"));
        return;
    };

    for (index, item) in items.iter().enumerate() {
        let Some(text) = item.as_str() else {
            errors.push(format!("field {field} must contain only strings"));
            continue;
        };
        if let Some(allowed) = allowed {
            if !allowed.iter().any(|allowed| allowed == &text) {
                if field == "disabled_hooks" {
                    errors.push(format!("disabled_hooks contains unsupported hook {text}"));
                } else {
                    errors.push(format!(".{field}.{index}: unsupported value {text}"));
                }
            }
        }
    }
}

fn validate_string_array_values(
    object: &serde_json::Map<String, Value>,
    field: &str,
    allowed: &[String],
    errors: &mut Vec<String>,
) {
    let Some(value) = object.get(field) else {
        return;
    };
    let Some(items) = value.as_array() else {
        errors.push(format!(".{field}: expected array"));
        return;
    };

    for item in items {
        let Some(text) = item.as_str() else {
            errors.push(format!("field {field} must contain only strings"));
            continue;
        };
        if !allowed.iter().any(|allowed| allowed == text) {
            errors.push(format!("disabled_hooks contains unsupported hook {text}"));
        }
    }
}

fn validate_disabled_rules(object: &serde_json::Map<String, Value>, errors: &mut Vec<String>) {
    let Some(value) = object.get("disabled_rules") else {
        return;
    };
    let Some(items) = value.as_array() else {
        errors.push(".disabled_rules: expected array".to_string());
        return;
    };

    for (index, item) in items.iter().enumerate() {
        let Some(text) = item.as_str() else {
            errors.push("field disabled_rules must contain only strings".to_string());
            continue;
        };
        if !valid_disabled_rule_id(text) {
            errors.push(format!(
                ".disabled_rules.{index}: unsupported rule id {text}"
            ));
        }
    }
}

fn validate_gc(object: &serde_json::Map<String, Value>, errors: &mut Vec<String>) {
    let Some(value) = object.get("gc") else {
        return;
    };
    let Some(gc) = value.as_object() else {
        errors.push(".gc: expected object".to_string());
        return;
    };
    for key in gc.keys() {
        if !GC_KEYS.iter().any(|allowed| allowed == &key.as_str()) {
            errors.push(unknown_property_error(&["gc", key.as_str()]));
        }
    }
    for (key, value) in gc {
        if !GC_KEYS.iter().any(|allowed| allowed == &key.as_str()) {
            continue;
        }
        let valid_positive_integer = match value.as_i64() {
            Some(number) => number >= 1,
            None => false,
        };
        if !valid_positive_integer {
            errors.push(format!(".gc.{key}: expected integer >= 1"));
        }
    }
}

fn unknown_property_error(path: &[&str]) -> String {
    let label = format!(".{}", path.join("."));
    let mut message = format!("{label}: unknown property");
    if path.len() == 1 {
        if let Some(hint) = runtime_config_key_hint(path[0]) {
            message.push_str("; ");
            message.push_str(hint);
        }
    }
    message
}

fn runtime_config_key_hint(key: &str) -> Option<&'static str> {
    match key {
        "write_mode" => Some("write_mode belongs in ~/.vibeguard/config.json, not .vibeguard.json"),
        "u16" => Some("u16.* belongs in ~/.vibeguard/config.json, not .vibeguard.json"),
        "circuit_breaker" => {
            Some("circuit_breaker.* belongs in ~/.vibeguard/config.json, not .vibeguard.json")
        }
        "paralysis" => Some("paralysis.* belongs in ~/.vibeguard/config.json, not .vibeguard.json"),
        _ => None,
    }
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

fn value_at_path<'a>(value: &'a Value, json_path: &str) -> Option<&'a Value> {
    let mut node = value;
    for key in json_path.split('.') {
        let object = node.as_object()?;
        node = object.get(key)?;
    }
    Some(node)
}

fn format_project_config_errors(path: &Path, errors: &[String]) -> String {
    format!(
        "VibeGuard project config invalid: {}\n  {}",
        path.display(),
        errors.join("\n  ")
    )
}

fn env_value(name: &str, env_overrides: &HashMap<String, String>) -> Option<String> {
    env_overrides
        .get(name)
        .filter(|value| !value.is_empty())
        .cloned()
        .or_else(|| std::env::var(name).ok().filter(|value| !value.is_empty()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const PROJECT_SCHEMA_JSON: &str = include_str!("../../schemas/vibeguard-project.schema.json");

    #[test]
    fn validation_reports_runtime_config_key_hints() {
        let path = Path::new("/tmp/.vibeguard.json");
        let value = json!({"write_mode":"block"});

        let err =
            validate_project_config_value(path, &value).expect_err("config should be invalid");

        assert!(err.contains(".write_mode: unknown property"));
        assert!(err.contains("write_mode belongs in ~/.vibeguard/config.json"));
    }

    #[test]
    fn validation_accumulates_gc_errors() {
        let path = Path::new("/tmp/.vibeguard.json");
        let value = json!({
            "gc": {
                "log_threshold_mb": 0,
                "unexpected_gc_key": 1
            },
            "unknown_top_level": true
        });

        let err =
            validate_project_config_value(path, &value).expect_err("config should be invalid");

        assert!(err.contains(".gc.log_threshold_mb: expected integer >= 1"));
        assert!(err.contains(".gc.unexpected_gc_key: unknown property"));
        assert!(err.contains(".unknown_top_level: unknown property"));
    }

    #[test]
    fn disabled_hooks_are_derived_from_manifest_and_schema() {
        let manifest_values = disabled_hook_values().expect("manifest disabled hooks should parse");
        assert!(manifest_values.contains(&"pre-bash-guard".to_string()));
        assert!(manifest_values.contains(&"analysis-paralysis-guard".to_string()));
        assert!(!manifest_values.contains(&"log".to_string()));

        let schema = serde_json::from_str::<Value>(PROJECT_SCHEMA_JSON)
            .expect("project schema should be valid JSON");
        let mut schema_values = schema["properties"]["disabled_hooks"]["items"]["enum"]
            .as_array()
            .expect("schema disabled_hooks enum should be an array")
            .iter()
            .map(|item| {
                item.as_str()
                    .expect("schema disabled_hooks enum entries should be strings")
                    .to_string()
            })
            .collect::<Vec<_>>();
        schema_values.sort();

        assert_eq!(manifest_values, schema_values);
    }

    #[test]
    fn validation_uses_manifest_disabled_hook_values() {
        let path = Path::new("/tmp/.vibeguard.json");
        let value = json!({"disabled_hooks":["pre-bash-guard"]});

        validate_project_config_value(path, &value)
            .expect("manifest-exposed disabled hook should be accepted");

        let err =
            validate_project_config_value(path, &json!({"disabled_hooks":["run-hook-codex"]}))
                .expect_err("manifest-unexposed wrapper should be rejected");

        assert!(err.contains("disabled_hooks contains unsupported hook run-hook-codex"));
    }
}
