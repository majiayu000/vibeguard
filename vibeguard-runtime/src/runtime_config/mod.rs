pub(crate) mod fields;
mod resolution;
pub mod validation;

use crate::HandlerResult;
use crate::runtime_config::validation::{
    RuntimeConfigDecision, RuntimeConfigError, classify_runtime_config_file,
};
use serde_json::Value;
use std::io::ErrorKind;
use std::path::PathBuf;
use std::process;
use std::sync::{Mutex, OnceLock};

static RUNTIME_CONFIG: OnceLock<Mutex<Option<CachedRuntimeConfig>>> = OnceLock::new();

#[derive(Clone)]
struct CachedRuntimeConfig {
    fingerprint: RuntimeConfigFingerprint,
    document: Result<Option<Value>, RuntimeConfigError>,
}

#[derive(Clone, PartialEq, Eq)]
struct RuntimeConfigFingerprint {
    path: PathBuf,
    contents: Result<Vec<u8>, ErrorKind>,
}

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

pub fn config(args: &[String]) -> HandlerResult {
    resolution::config_command(args)
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

/// Print one entry per line for a declared string-array field.
///
/// The whole config is validated before any value is read, so a malformed file
/// exits non-zero here instead of degrading into an empty list — an empty list
/// would silently reverse an explicit user opt-out (GH719).
pub fn runtime_config_get_list(args: &[String]) -> HandlerResult {
    if args.len() != 2 {
        return Err(
            "Usage: vibeguard-runtime runtime-config-get-list <env-name> <json-path>".into(),
        );
    }

    for entry in resolve_runtime_config_list(&args[0], &args[1])? {
        println!("{entry}");
    }
    Ok(())
}

fn resolve_runtime_config_list(
    env_name: &str,
    json_path: &str,
) -> Result<Vec<String>, RuntimeConfigError> {
    resolution::resolve_list(env_name, json_path, None).map(|resolved| resolved.value)
}

pub(crate) fn runtime_config_int_value(
    env_name: &str,
    json_path: &str,
    default_value: &str,
) -> u64 {
    resolve_runtime_config_int(env_name, json_path, default_value)
        .unwrap_or_else(exit_runtime_config_error)
}

pub(crate) fn runtime_config_int_value_for_cwd(
    env_name: &str,
    json_path: &str,
    default_value: &str,
    cwd: Option<&str>,
) -> Result<u64, RuntimeConfigError> {
    resolution::resolve_int(env_name, json_path, default_value, cwd).map(|resolved| resolved.value)
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
    resolution::resolve_int(env_name, json_path, default_value, None).map(|resolved| resolved.value)
}

fn resolve_runtime_config_str(
    env_name: &str,
    json_path: &str,
    default_value: &str,
) -> Result<String, RuntimeConfigError> {
    resolution::resolve_str(env_name, json_path, default_value, None).map(|resolved| resolved.value)
}

fn loaded_runtime_config() -> Result<Option<Value>, RuntimeConfigError> {
    let path = runtime_config_file();
    let fingerprint = RuntimeConfigFingerprint {
        contents: std::fs::read(&path).map_err(|error| error.kind()),
        path: path.clone(),
    };
    let cache = RUNTIME_CONFIG.get_or_init(|| Mutex::new(None));
    let mut entry = cache.lock().map_err(|_| RuntimeConfigError {
        message: "VibeGuard runtime config cache unavailable: category=config_internal_error"
            .into(),
        exit_code: 20,
    })?;
    if let Some(cached) = entry.as_ref()
        && cached.fingerprint == fingerprint
    {
        return cached.document.clone();
    }
    let path_text = path.to_string_lossy();
    let document = classify_runtime_config_file(&path_text).map(|(_, value)| value);
    *entry = Some(CachedRuntimeConfig {
        fingerprint,
        document: document.clone(),
    });
    document
}

fn exit_runtime_config_error<T>(error: RuntimeConfigError) -> T {
    eprintln!("{}", error.message);
    process::exit(error.exit_code);
}

fn runtime_config_file() -> PathBuf {
    if let Ok(path) = std::env::var("VG_INTERNAL_CONFIG_FILE")
        && !path.is_empty()
    {
        return PathBuf::from(path);
    }
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
