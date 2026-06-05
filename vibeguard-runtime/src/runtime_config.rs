use crate::HandlerResult;
use serde_json::Value;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeConfigError {
    pub message: String,
    pub exit_code: i32,
}

impl RuntimeConfigError {
    fn config_parse_error(message: String) -> Self {
        Self {
            message,
            exit_code: 30,
        }
    }

    fn policy_error(message: String) -> Self {
        Self {
            message,
            exit_code: 20,
        }
    }
}

pub fn validate_runtime_config_file(path_text: &str) -> Result<(), RuntimeConfigError> {
    if path_text.is_empty() {
        return Ok(());
    }

    let path = Path::new(path_text);
    if !path.is_file() {
        return Ok(());
    }

    let text = std::fs::read_to_string(path).map_err(|err| {
        if err.kind() == ErrorKind::InvalidData {
            RuntimeConfigError::config_parse_error(format!(
                "VibeGuard runtime config invalid UTF-8: {}: {err}",
                path.display()
            ))
        } else {
            RuntimeConfigError::policy_error(format!(
                "VibeGuard runtime config cannot be read: {}: {err}",
                path.display()
            ))
        }
    })?;

    serde_json::from_str::<serde_json::Value>(&text).map_err(|err| {
        RuntimeConfigError::config_parse_error(format!(
            "VibeGuard runtime config invalid JSON: {}: {err}",
            path.display()
        ))
    })?;

    Ok(())
}

pub fn runtime_config_get_int(args: &[String]) -> HandlerResult {
    if args.len() != 3 {
        return Err(
            "Usage: vibeguard-runtime runtime-config-get-int <env-name> <json-path> <default>"
                .into(),
        );
    }

    let env_name = &args[0];
    let json_path = &args[1];
    let default_value = &args[2];

    if let Some(value) = std::env::var(env_name)
        .ok()
        .filter(|value| is_nonnegative_digits(value))
    {
        println!("{value}");
        return Ok(());
    }

    if let Some(value) = load_runtime_config_value(json_path) {
        if let Some(number) = value.as_u64() {
            println!("{number}");
            return Ok(());
        }
    }

    println!("{default_value}");
    Ok(())
}

pub fn runtime_config_get_str(args: &[String]) -> HandlerResult {
    if args.len() != 3 {
        return Err(
            "Usage: vibeguard-runtime runtime-config-get-str <env-name> <json-path> <default>"
                .into(),
        );
    }

    let env_name = &args[0];
    let json_path = &args[1];
    let default_value = &args[2];

    if let Some(value) = std::env::var(env_name)
        .ok()
        .filter(|value| !value.is_empty())
    {
        println!("{value}");
        return Ok(());
    }

    if let Some(value) = load_runtime_config_value(json_path) {
        if let Some(text) = value.as_str().filter(|text| !text.is_empty()) {
            println!("{text}");
            return Ok(());
        }
    }

    println!("{default_value}");
    Ok(())
}

fn load_runtime_config_value(json_path: &str) -> Option<Value> {
    let path = runtime_config_file();
    if !path.is_file() {
        return None;
    }
    let text = std::fs::read_to_string(path).ok()?;
    let value = serde_json::from_str::<Value>(&text).ok()?;
    value_at_path(&value, json_path).cloned()
}

fn runtime_config_file() -> PathBuf {
    if let Ok(path) = std::env::var("_VG_CONFIG_FILE") {
        if !path.is_empty() {
            return PathBuf::from(path);
        }
    }
    if let Ok(path) = std::env::var("VIBEGUARD_CONFIG_FILE") {
        if !path.is_empty() {
            return PathBuf::from(path);
        }
    }
    if let Ok(log_dir) = std::env::var("VIBEGUARD_LOG_DIR") {
        if !log_dir.is_empty() {
            return PathBuf::from(log_dir).join("config.json");
        }
    }
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into()))
        .join(".vibeguard")
        .join("config.json")
}

fn is_nonnegative_digits(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit())
}

fn value_at_path<'a>(value: &'a Value, json_path: &str) -> Option<&'a Value> {
    let mut node = value;
    for key in json_path.split('.') {
        let object = node.as_object()?;
        node = object.get(key)?;
    }
    Some(node)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn nonnegative_digits_rejects_empty_signed_and_alpha_values() {
        assert!(is_nonnegative_digits("0"));
        assert!(is_nonnegative_digits("123"));
        assert!(!is_nonnegative_digits(""));
        assert!(!is_nonnegative_digits("-1"));
        assert!(!is_nonnegative_digits("12x"));
    }

    #[test]
    fn value_at_path_reads_nested_objects_only() {
        let value = json!({"u16":{"limit":1234},"items":[1]});
        assert_eq!(value_at_path(&value, "u16.limit"), Some(&json!(1234)));
        assert_eq!(value_at_path(&value, "u16.missing"), None);
        assert_eq!(value_at_path(&value, "items.0"), None);
    }
}
