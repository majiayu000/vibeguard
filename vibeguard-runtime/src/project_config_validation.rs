use serde_json::Value;
use std::path::Path;

use crate::codex_app_server_policy::valid_disabled_rule_id;

pub fn validate_path(path: &Path) -> Result<(), String> {
    let text = std::fs::read_to_string(path).map_err(|err| {
        format!(
            "VibeGuard project config invalid: {}: cannot read file ({err})",
            path.display()
        )
    })?;
    let value = serde_json::from_str::<Value>(&text).map_err(|err| {
        format!(
            "VibeGuard project config invalid: {}: invalid JSON: {err}",
            path.display()
        )
    })?;
    let Some(object) = value.as_object() else {
        return Err(format!(
            "VibeGuard project config invalid: {}\n  $: expected object",
            path.display()
        ));
    };

    let errors = collect_project_config_errors(object);
    if errors.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "VibeGuard project config invalid: {}\n  {}",
            path.display(),
            errors.join("\n  ")
        ))
    }
}

fn collect_project_config_errors(object: &serde_json::Map<String, Value>) -> Vec<String> {
    let mut errors = Vec::new();
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

    collect_string_enum(
        object,
        "profile",
        &["core", "full", "minimal", "strict"],
        &mut errors,
    );
    collect_string_enum(
        object,
        "enforcement",
        &["block", "off", "warn"],
        &mut errors,
    );
    collect_string_array_enum(
        object,
        "languages",
        &["go", "javascript", "python", "rust", "typescript"],
        &mut errors,
    );
    collect_string_array_enum(
        object,
        "disabled_hooks",
        &[
            "analysis-paralysis-guard",
            "count-active-constraints",
            "learn-evaluator",
            "post-build-check",
            "post-edit-guard",
            "post-write-guard",
            "pre-bash-guard",
            "pre-commit-guard",
            "pre-edit-guard",
            "pre-write-guard",
            "stop-guard",
        ],
        &mut errors,
    );
    collect_string_array_enum(
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
        &mut errors,
    );
    collect_disabled_rules(object, &mut errors);
    collect_gc_errors(object, &mut errors);
    errors
}

fn collect_string_enum(
    object: &serde_json::Map<String, Value>,
    field: &str,
    allowed: &[&str],
    errors: &mut Vec<String>,
) {
    let Some(value) = object.get(field) else {
        return;
    };
    let path = format!(".{field}");
    let Some(text) = value.as_str() else {
        errors.push(format!("{path}: expected string"));
        return;
    };
    if !allowed.iter().any(|allowed| allowed == &text) {
        errors.push(format!(
            "{path}: unsupported value {text:?}; expected one of {allowed:?}"
        ));
    }
}

fn collect_string_array_enum(
    object: &serde_json::Map<String, Value>,
    field: &str,
    allowed: &[&str],
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
        let path = format!(".{field}.{index}");
        let Some(text) = item.as_str() else {
            errors.push(format!("{path}: expected string"));
            continue;
        };
        if !allowed.iter().any(|allowed| allowed == &text) {
            errors.push(format!(
                "{path}: unsupported value {text:?}; expected one of {allowed:?}"
            ));
        }
    }
}

fn collect_disabled_rules(object: &serde_json::Map<String, Value>, errors: &mut Vec<String>) {
    let Some(value) = object.get("disabled_rules") else {
        return;
    };
    let Some(items) = value.as_array() else {
        errors.push(".disabled_rules: expected array".into());
        return;
    };
    for (index, item) in items.iter().enumerate() {
        let path = format!(".disabled_rules.{index}");
        let Some(rule) = item.as_str() else {
            errors.push(format!("{path}: expected string"));
            continue;
        };
        if !valid_disabled_rule_id(rule) {
            errors.push(format!(
                "{path}: does not match ^(SEC|RS|GO|TS|PY|U|W|TASTE)-[A-Za-z0-9-]+$"
            ));
        }
    }
}

fn collect_gc_errors(object: &serde_json::Map<String, Value>, errors: &mut Vec<String>) {
    let Some(value) = object.get("gc") else {
        return;
    };
    let Some(gc) = value.as_object() else {
        errors.push(".gc: expected object".into());
        return;
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
            errors.push(unknown_property_error(&["gc", key.as_str()]));
        }
    }
    for (key, value) in gc {
        if !allowed.iter().any(|allowed| allowed == &key.as_str()) {
            continue;
        }
        if value.is_boolean() || value.as_i64().filter(|number| *number >= 1).is_none() {
            errors.push(format!(".gc.{key}: expected integer >= 1"));
        }
    }
}

fn unknown_property_error(path: &[&str]) -> String {
    let label = format!(".{}", path.join("."));
    let hint = match path {
        ["write_mode"] => {
            Some("write_mode belongs in ~/.vibeguard/config.json, not .vibeguard.json")
        }
        ["u16"] => Some("u16.* belongs in ~/.vibeguard/config.json, not .vibeguard.json"),
        ["circuit_breaker"] => {
            Some("circuit_breaker.* belongs in ~/.vibeguard/config.json, not .vibeguard.json")
        }
        ["paralysis"] => {
            Some("paralysis.* belongs in ~/.vibeguard/config.json, not .vibeguard.json")
        }
        _ => None,
    };
    match hint {
        Some(hint) => format!("{label}: unknown property; {hint}"),
        None => format!("{label}: unknown property"),
    }
}
