use serde_json::Value;
use std::fmt;
use std::io::ErrorKind;
use std::path::Path;

const CONFIG_PARSE_ERROR: i32 = 30;
const POLICY_ERROR: i32 = 20;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeConfigError {
    pub message: String,
    pub exit_code: i32,
}

impl fmt::Display for RuntimeConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for RuntimeConfigError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimeConfigDecision {
    Missing,
    Valid,
}

#[derive(Debug, Clone, Copy)]
enum FieldKind {
    Integer { minimum: u64, maximum: u64 },
    StringEnum { allowed: &'static [&'static str] },
    Version,
}

#[derive(Debug, Clone, Copy)]
struct RuntimeConfigField {
    path: &'static str,
    kind: FieldKind,
}

const RUNTIME_CONFIG_FIELDS: &[RuntimeConfigField] = &[
    RuntimeConfigField {
        path: "version",
        kind: FieldKind::Version,
    },
    RuntimeConfigField {
        path: "u16.warn_limit",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 1_000_000,
        },
    },
    RuntimeConfigField {
        path: "u16.limit",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 1_000_000,
        },
    },
    RuntimeConfigField {
        path: "circuit_breaker.threshold",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 1_000_000,
        },
    },
    RuntimeConfigField {
        path: "circuit_breaker.cooldown_seconds",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 31_536_000,
        },
    },
    RuntimeConfigField {
        path: "circuit_breaker.lock_timeout_seconds",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 300,
        },
    },
    RuntimeConfigField {
        path: "w14.cooldown_seconds",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 31_536_000,
        },
    },
    RuntimeConfigField {
        path: "paralysis.threshold",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 1_000_000,
        },
    },
    RuntimeConfigField {
        path: "write_mode",
        kind: FieldKind::StringEnum {
            allowed: &["warn", "block"],
        },
    },
    RuntimeConfigField {
        path: "write_escalate_threshold",
        kind: FieldKind::Integer {
            minimum: 0,
            maximum: 1_000_000,
        },
    },
    RuntimeConfigField {
        path: "learn.metrics_tail_bytes",
        kind: FieldKind::Integer {
            minimum: 1,
            maximum: 268_435_456,
        },
    },
];

pub fn classify_runtime_config_file(
    path_text: &str,
) -> Result<(RuntimeConfigDecision, Option<Value>), RuntimeConfigError> {
    if path_text.is_empty() {
        return Ok((RuntimeConfigDecision::Missing, None));
    }

    let path = Path::new(path_text);
    let link_metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(err) if err.kind() == ErrorKind::NotFound => {
            return Ok((RuntimeConfigDecision::Missing, None));
        }
        Err(err) => return Err(read_error(path, err.kind())),
    };

    let metadata = if link_metadata.file_type().is_symlink() {
        match std::fs::metadata(path) {
            Ok(metadata) => metadata,
            Err(err) if err.kind() == ErrorKind::NotFound => {
                return Err(config_error(
                    path,
                    "$",
                    "config_path_target_error",
                    "symlink_target=readable_regular_file",
                    POLICY_ERROR,
                ));
            }
            Err(err) => return Err(read_error(path, err.kind())),
        }
    } else {
        link_metadata
    };

    if !metadata.is_file() {
        return Err(config_error(
            path,
            "$",
            "config_path_type_error",
            "path_type=regular_file",
            POLICY_ERROR,
        ));
    }

    let bytes = std::fs::read(path).map_err(|err| read_error(path, err.kind()))?;
    let text = String::from_utf8(bytes).map_err(|_| {
        config_error(
            path,
            "$",
            "config_utf8_error",
            "encoding=utf-8",
            CONFIG_PARSE_ERROR,
        )
    })?;
    let value = serde_json::from_str::<Value>(&text).map_err(|err| {
        config_error(
            path,
            "$",
            "config_json_error",
            &format!("valid_json line={} column={}", err.line(), err.column()),
            CONFIG_PARSE_ERROR,
        )
    })?;
    validate_runtime_config_value(path, &value)?;
    Ok((RuntimeConfigDecision::Valid, Some(value)))
}

fn read_error(path: &Path, kind: ErrorKind) -> RuntimeConfigError {
    config_error(
        path,
        "$",
        "config_read_error",
        &format!("readable_regular_file error_kind={kind:?}"),
        POLICY_ERROR,
    )
}

fn config_error(
    path: &Path,
    json_path: &str,
    category: &str,
    expected: &str,
    exit_code: i32,
) -> RuntimeConfigError {
    RuntimeConfigError {
        message: format!(
            "VibeGuard runtime config invalid: {}: path={json_path} category={category} expected={expected}",
            path.display()
        ),
        exit_code,
    }
}

fn validate_runtime_config_value(path: &Path, value: &Value) -> Result<(), RuntimeConfigError> {
    validate_object(path, "$", "", value)
}

fn validate_object(
    file_path: &Path,
    display_path: &str,
    field_prefix: &str,
    value: &Value,
) -> Result<(), RuntimeConfigError> {
    let object = value.as_object().ok_or_else(|| {
        config_error(
            file_path,
            display_path,
            "config_type_error",
            "type=object",
            CONFIG_PARSE_ERROR,
        )
    })?;

    for (key, child) in object {
        let field_path = if field_prefix.is_empty() {
            key.to_string()
        } else {
            format!("{field_prefix}.{key}")
        };
        let child_display_path = format!("$.{field_path}");
        if let Some(field) = RUNTIME_CONFIG_FIELDS
            .iter()
            .find(|field| field.path == field_path)
        {
            validate_field(file_path, &child_display_path, child, field.kind)?;
        } else if RUNTIME_CONFIG_FIELDS
            .iter()
            .any(|field| field.path.starts_with(&format!("{field_path}.")))
        {
            validate_object(file_path, &child_display_path, &field_path, child)?;
        } else {
            return Err(config_error(
                file_path,
                &child_display_path,
                "config_unknown_field",
                "field=declared_runtime_config_path",
                CONFIG_PARSE_ERROR,
            ));
        }
    }
    Ok(())
}

fn validate_field(
    file_path: &Path,
    display_path: &str,
    value: &Value,
    kind: FieldKind,
) -> Result<(), RuntimeConfigError> {
    match kind {
        FieldKind::Integer { minimum, maximum } => {
            let integer = if let Some(integer) = value.as_u64() {
                integer
            } else if value.as_i64().is_some() {
                return Err(config_error(
                    file_path,
                    display_path,
                    "config_range_error",
                    &format!("integer_range={minimum}..={maximum}"),
                    CONFIG_PARSE_ERROR,
                ));
            } else {
                return Err(config_error(
                    file_path,
                    display_path,
                    "config_type_error",
                    "type=integer",
                    CONFIG_PARSE_ERROR,
                ));
            };
            if integer < minimum || integer > maximum {
                return Err(config_error(
                    file_path,
                    display_path,
                    "config_range_error",
                    &format!("integer_range={minimum}..={maximum}"),
                    CONFIG_PARSE_ERROR,
                ));
            }
        }
        FieldKind::StringEnum { allowed } => {
            let text = value.as_str().ok_or_else(|| {
                config_error(
                    file_path,
                    display_path,
                    "config_type_error",
                    "type=string",
                    CONFIG_PARSE_ERROR,
                )
            })?;
            if !allowed.contains(&text) {
                return Err(config_error(
                    file_path,
                    display_path,
                    "config_enum_error",
                    &format!("allowed={}", allowed.join("|")),
                    CONFIG_PARSE_ERROR,
                ));
            }
        }
        FieldKind::Version => {
            let version = value.as_u64().ok_or_else(|| {
                config_error(
                    file_path,
                    display_path,
                    "config_type_error",
                    "type=integer",
                    CONFIG_PARSE_ERROR,
                )
            })?;
            if version != 1 {
                return Err(config_error(
                    file_path,
                    display_path,
                    "config_version_error",
                    "supported_version=1",
                    CONFIG_PARSE_ERROR,
                ));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::BTreeSet;

    fn schema_leaf_paths(value: &Value, prefix: &str, paths: &mut BTreeSet<String>) {
        let properties = value["properties"]
            .as_object()
            .expect("schema object should have properties");
        for (key, child) in properties {
            let path = if prefix.is_empty() {
                key.to_string()
            } else {
                format!("{prefix}.{key}")
            };
            if child["type"] == "object" {
                schema_leaf_paths(child, &path, paths);
            } else {
                paths.insert(path);
            }
        }
    }

    fn value_leaf_paths(value: &Value, prefix: &str, paths: &mut BTreeSet<String>) {
        for (key, child) in value.as_object().expect("template should be an object") {
            let path = if prefix.is_empty() {
                key.to_string()
            } else {
                format!("{prefix}.{key}")
            };
            if child.is_object() {
                value_leaf_paths(child, &path, paths);
            } else {
                paths.insert(path);
            }
        }
    }

    #[test]
    fn runtime_config_inventory_matches_schema_and_template() {
        let schema: Value = serde_json::from_str(include_str!(
            "../../schemas/vibeguard-runtime-config.schema.json"
        ))
        .expect("runtime config schema should parse");
        let template: Value = serde_json::from_str(include_str!(
            "../../templates/vibeguard-config.json.example"
        ))
        .expect("runtime config template should parse");

        let rust_paths = RUNTIME_CONFIG_FIELDS
            .iter()
            .map(|field| field.path.to_string())
            .collect::<BTreeSet<_>>();
        let mut schema_paths = BTreeSet::new();
        schema_leaf_paths(&schema, "", &mut schema_paths);
        let mut template_paths = BTreeSet::new();
        value_leaf_paths(&template, "", &mut template_paths);

        assert_eq!(schema_paths, rust_paths);
        assert_eq!(template_paths, rust_paths);
        validate_runtime_config_value(Path::new("template"), &template)
            .expect("published template should pass the Rust validator");
    }

    #[test]
    fn runtime_config_semantics_reject_unknown_type_enum_range_and_version() {
        for (value, category) in [
            (json!({"unknown": 1}), "config_unknown_field"),
            (json!({"u16": {"limit": "800"}}), "config_type_error"),
            (json!({"write_mode": "secret-value"}), "config_enum_error"),
            (
                json!({"learn": {"metrics_tail_bytes": 0}}),
                "config_range_error",
            ),
            (json!({"version": 2}), "config_version_error"),
        ] {
            let error = validate_runtime_config_value(Path::new("config.json"), &value)
                .expect_err("invalid config should fail");
            assert!(error.message.contains(category));
            assert!(!error.message.contains("secret-value"));
        }
    }

    #[test]
    fn runtime_config_semantics_accept_empty_partial_and_legacy_clamp_inputs() {
        for value in [
            json!({}),
            json!({"version": 1}),
            json!({"u16": {"limit": 800}}),
            json!({"u16": {"warn_limit": 900, "limit": 800}}),
        ] {
            validate_runtime_config_value(Path::new("config.json"), &value)
                .expect("compatible config should pass");
        }
    }
}
