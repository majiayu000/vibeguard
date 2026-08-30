use serde_json::Value;
use std::fmt;
use std::io::ErrorKind;
use std::path::Path;

use super::fields::{FieldKind, RUNTIME_CONFIG_FIELDS};

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
    let value = serde_json::from_str::<Value>(&text).map_err(|err| RuntimeConfigError {
        message: format!(
            "VibeGuard runtime config invalid JSON: {}: path=$ category=config_json_error expected=valid_json line={} column={}",
            path.display(),
            err.line(),
            err.column()
        ),
        exit_code: CONFIG_PARSE_ERROR,
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

pub(crate) fn validate_runtime_config_overlay(
    path: &Path,
    value: &Value,
) -> Result<(), RuntimeConfigError> {
    validate_runtime_config_value(path, value)
}

pub(crate) fn validate_effective_churn_threshold_order(
    informational: u64,
    warning: u64,
    critical: u64,
) -> Result<(), RuntimeConfigError> {
    validate_churn_threshold_values(
        "effective configuration",
        informational,
        warning,
        critical,
        POLICY_ERROR,
    )
}

fn validate_churn_threshold_values(
    source: &str,
    informational: u64,
    warning: u64,
    critical: u64,
    exit_code: i32,
) -> Result<(), RuntimeConfigError> {
    if informational <= warning && warning <= critical {
        return Ok(());
    }
    Err(RuntimeConfigError {
        message: format!(
            "VibeGuard runtime config invalid: {source}: path=$.churn category=config_range_error expected=ordered=informational_edit_count<=warning_edit_count<=critical_edit_count actual={informational},{warning},{critical}"
        ),
        exit_code,
    })
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
            let integer = if let Some(integer) = nonnegative_json_integer(value) {
                integer
            } else if is_json_schema_integer(value) {
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
        FieldKind::StringArray { maximum_items } => {
            let items = value.as_array().ok_or_else(|| {
                config_error(
                    file_path,
                    display_path,
                    "config_type_error",
                    "type=array",
                    CONFIG_PARSE_ERROR,
                )
            })?;
            if items.len() > maximum_items {
                return Err(config_error(
                    file_path,
                    display_path,
                    "config_range_error",
                    &format!("array_max_items={maximum_items}"),
                    CONFIG_PARSE_ERROR,
                ));
            }
            for (index, item) in items.iter().enumerate() {
                let Some(text) = item.as_str() else {
                    return Err(config_error(
                        file_path,
                        &format!("{display_path}[{index}]"),
                        "config_type_error",
                        "type=nonempty_string",
                        CONFIG_PARSE_ERROR,
                    ));
                };
                if text.trim().is_empty() {
                    return Err(config_error(
                        file_path,
                        &format!("{display_path}[{index}]"),
                        "config_type_error",
                        "type=nonempty_string",
                        CONFIG_PARSE_ERROR,
                    ));
                }
                if !is_skill_name(text) {
                    return Err(config_error(
                        file_path,
                        &format!("{display_path}[{index}]"),
                        "config_value_error",
                        "pattern=^[A-Za-z0-9][A-Za-z0-9._-]*$",
                        POLICY_ERROR,
                    ));
                }
            }
        }
        FieldKind::Version => {
            let version = if let Some(version) = nonnegative_json_integer(value) {
                version
            } else if is_json_schema_integer(value) {
                return Err(config_error(
                    file_path,
                    display_path,
                    "config_version_error",
                    "supported_version=1",
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

pub(crate) fn is_skill_name(value: &str) -> bool {
    let mut bytes = value.bytes();
    let Some(first) = bytes.next() else {
        return false;
    };
    first.is_ascii_alphanumeric()
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

pub(crate) fn nonnegative_json_integer(value: &Value) -> Option<u64> {
    if let Some(integer) = value.as_u64() {
        return Some(integer);
    }
    let number = value.as_f64()?;
    if number.is_finite() && number >= 0.0 && number.fract() == 0.0 && number <= u64::MAX as f64 {
        let integer = number as u64;
        if integer as f64 == number {
            return Some(integer);
        }
    }
    None
}

fn is_json_schema_integer(value: &Value) -> bool {
    value.as_i64().is_some()
        || value.as_u64().is_some()
        || value
            .as_f64()
            .is_some_and(|number| number.is_finite() && number.fract() == 0.0)
}

#[cfg(test)]
#[path = "validation_tests.rs"]
mod tests;
