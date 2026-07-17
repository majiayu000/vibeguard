use crate::HandlerResult;
use crate::runtime_config_validation::{
    RuntimeConfigDecision, RuntimeConfigError, classify_runtime_config_file,
    nonnegative_json_integer,
};
use serde_json::Value;
use std::path::PathBuf;
use std::process;
use std::sync::OnceLock;

static RUNTIME_CONFIG: OnceLock<Result<Option<Value>, RuntimeConfigError>> = OnceLock::new();

pub fn validate_runtime_config_file(path_text: &str) -> Result<(), RuntimeConfigError> {
    classify_runtime_config_file(path_text).map(|_| ())
}

pub fn runtime_config_validate(args: &[String]) -> HandlerResult {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime runtime-config-validate <config-file>".into());
    }
    let (decision, _) = classify_runtime_config_file(&args[0])?;
    match decision {
        RuntimeConfigDecision::Missing => println!("MISSING"),
        RuntimeConfigDecision::Valid => println!("VALID"),
    }
    Ok(())
}

pub fn runtime_config_get_int(args: &[String]) -> HandlerResult {
    if args.len() != 3 {
        return Err(
            "Usage: vibeguard-runtime runtime-config-get-int <env-name> <json-path> <default>"
                .into(),
        );
    }

    println!(
        "{}",
        resolve_runtime_config_int(&args[0], &args[1], &args[2])?
    );
    Ok(())
}

pub fn runtime_config_get_str(args: &[String]) -> HandlerResult {
    if args.len() != 3 {
        return Err(
            "Usage: vibeguard-runtime runtime-config-get-str <env-name> <json-path> <default>"
                .into(),
        );
    }

    println!(
        "{}",
        resolve_runtime_config_str(&args[0], &args[1], &args[2])?
    );
    Ok(())
}

pub(crate) fn runtime_config_int_value(
    env_name: &str,
    json_path: &str,
    default_value: &str,
) -> u64 {
    resolve_runtime_config_int(env_name, json_path, default_value)
        .unwrap_or_else(exit_runtime_config_error)
}

pub(crate) fn runtime_config_str_value(
    env_name: &str,
    json_path: &str,
    default_value: &str,
) -> String {
    resolve_runtime_config_str(env_name, json_path, default_value)
        .unwrap_or_else(exit_runtime_config_error)
}

fn resolve_runtime_config_int(
    env_name: &str,
    json_path: &str,
    default_value: &str,
) -> Result<u64, RuntimeConfigError> {
    let config = loaded_runtime_config()?;
    if let Some(value) = std::env::var(env_name)
        .ok()
        .filter(|value| is_nonnegative_digits(value))
        .and_then(|value| value.parse::<u64>().ok())
    {
        return Ok(value);
    }

    if let Some(value) = config
        .and_then(|value| value_at_path(value, json_path))
        .and_then(nonnegative_json_integer)
    {
        return Ok(value);
    }

    default_value.parse::<u64>().map_err(|_| RuntimeConfigError {
        message: "VibeGuard runtime config default invalid: category=default_type_error expected=nonnegative_integer".into(),
        exit_code: 20,
    })
}

fn resolve_runtime_config_str(
    env_name: &str,
    json_path: &str,
    default_value: &str,
) -> Result<String, RuntimeConfigError> {
    let config = loaded_runtime_config()?;
    if let Some(value) = std::env::var(env_name)
        .ok()
        .filter(|value| !value.is_empty())
    {
        return Ok(value);
    }

    if let Some(text) = config
        .and_then(|value| value_at_path(value, json_path))
        .and_then(Value::as_str)
    {
        return Ok(text.to_string());
    }

    Ok(default_value.to_string())
}

fn loaded_runtime_config() -> Result<Option<&'static Value>, RuntimeConfigError> {
    let result = RUNTIME_CONFIG.get_or_init(|| {
        let path = runtime_config_file();
        let path_text = path.to_string_lossy();
        classify_runtime_config_file(&path_text).map(|(_, value)| value)
    });
    match result {
        Ok(value) => Ok(value.as_ref()),
        Err(error) => Err(error.clone()),
    }
}

fn exit_runtime_config_error<T>(error: RuntimeConfigError) -> T {
    eprintln!("{}", error.message);
    process::exit(error.exit_code);
}

fn runtime_config_file() -> PathBuf {
    if let Ok(path) = std::env::var("_VG_CONFIG_FILE")
        && !path.is_empty()
    {
        return PathBuf::from(path);
    }
    if let Ok(path) = std::env::var("VIBEGUARD_CONFIG_FILE")
        && !path.is_empty()
    {
        return PathBuf::from(path);
    }
    if let Ok(log_dir) = std::env::var("VIBEGUARD_LOG_DIR")
        && !log_dir.is_empty()
    {
        return PathBuf::from(log_dir).join("config.json");
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
