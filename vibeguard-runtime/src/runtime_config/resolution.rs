use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use crate::HandlerResult;
use crate::project_config::{project_config_path, validated_project_config_json};

use super::fields::{FieldKind, RuntimeConfigField, field_for_key};
use super::validation::{RuntimeConfigError, is_skill_name, nonnegative_json_integer};
use super::{is_nonnegative_digits, loaded_runtime_config, runtime_config_file, value_at_path};

static PROJECT_CONFIGS: OnceLock<
    Mutex<HashMap<String, Result<Option<ProjectDocument>, RuntimeConfigError>>>,
> = OnceLock::new();

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ConfigSource {
    Default,
    UserConfig,
    ProjectConfig,
    Environment,
}

impl ConfigSource {
    fn source_name(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::UserConfig => "user_config",
            Self::ProjectConfig => "project_config",
            Self::Environment => "environment",
        }
    }
}

pub(super) struct Resolved<T> {
    pub value: T,
    source: ConfigSource,
    detail: String,
}

pub(super) fn resolve_int(
    env_name: &str,
    json_path: &str,
    default_value: &str,
    cwd: Option<&str>,
) -> Result<Resolved<u64>, RuntimeConfigError> {
    let layers = config_layers(json_path, cwd)?;
    if let Ok(raw) = std::env::var(env_name)
        && !raw.is_empty()
    {
        let value = parse_environment_int(&raw, env_name, json_path)?;
        return Ok(resolved(value, ConfigSource::Environment, env_name));
    }
    if let Some((value, path)) = layers.project
        && let Some(value) = nonnegative_json_integer(&value)
    {
        return Ok(resolved(value, ConfigSource::ProjectConfig, path));
    }
    if let Some(value) = layers.user.and_then(nonnegative_json_integer) {
        return Ok(resolved(value, ConfigSource::UserConfig, layers.user_path));
    }
    let value = default_value.parse::<u64>().map_err(|_| RuntimeConfigError {
        message: "VibeGuard runtime config default invalid: category=default_type_error expected=nonnegative_integer".into(),
        exit_code: 20,
    })?;
    Ok(resolved(value, ConfigSource::Default, "built-in"))
}

pub(super) fn resolve_str(
    env_name: &str,
    json_path: &str,
    default_value: &str,
    cwd: Option<&str>,
) -> Result<Resolved<String>, RuntimeConfigError> {
    let layers = config_layers(json_path, cwd)?;
    if let Some(value) = std::env::var(env_name)
        .ok()
        .filter(|value| !value.is_empty())
    {
        validate_environment_string(&value, env_name, json_path)?;
        return Ok(resolved(value, ConfigSource::Environment, env_name));
    }
    if let Some((value, path)) = layers.project
        && let Some(value) = value.as_str()
    {
        return Ok(resolved(
            value.to_string(),
            ConfigSource::ProjectConfig,
            path,
        ));
    }
    if let Some(value) = layers.user.and_then(Value::as_str) {
        return Ok(resolved(
            value.to_string(),
            ConfigSource::UserConfig,
            layers.user_path,
        ));
    }
    Ok(resolved(
        default_value.to_string(),
        ConfigSource::Default,
        "built-in",
    ))
}

pub(super) fn resolve_list(
    env_name: &str,
    json_path: &str,
    cwd: Option<&str>,
) -> Result<Resolved<Vec<String>>, RuntimeConfigError> {
    let layers = config_layers(json_path, cwd)?;
    if let Ok(raw) = std::env::var(env_name) {
        let value = parse_skill_list(&raw, env_name, json_path)?;
        return Ok(resolved(value, ConfigSource::Environment, env_name));
    }
    if let Some((value, path)) = layers.project
        && let Some(items) = value.as_array()
    {
        return Ok(resolved(
            string_items(items),
            ConfigSource::ProjectConfig,
            path,
        ));
    }
    if let Some(items) = layers.user.and_then(Value::as_array) {
        return Ok(resolved(
            string_items(items),
            ConfigSource::UserConfig,
            layers.user_path,
        ));
    }
    Ok(resolved(Vec::new(), ConfigSource::Default, "built-in"))
}

pub(super) fn config_command(args: &[String]) -> HandlerResult {
    let ParsedExplain { key, cwd, json } = parse_explain_args(args)?;
    let field = field_for_key(&key).ok_or_else(|| {
        format!(
            "unknown supported config key {key}; use a documented JSON path or environment name"
        )
    })?;
    let resolved = resolve_field(field, cwd.as_deref())?;
    if json {
        println!(
            "{}",
            serde_json::to_string(&json!({
                "key": field.path,
                "value": resolved.value,
                "source": resolved.source.source_name(),
                "source_detail": resolved.detail,
                "environment": field.env,
            }))?
        );
    } else {
        println!("{}={}", field.path, display_value(&resolved.value));
        println!("source={}", resolved.source.source_name());
        println!("source_detail={}", resolved.detail);
        println!("environment={}", field.env.unwrap_or("none"));
    }
    Ok(())
}

struct ParsedExplain {
    key: String,
    cwd: Option<String>,
    json: bool,
}

fn parse_explain_args(args: &[String]) -> Result<ParsedExplain, Box<dyn std::error::Error>> {
    if args.first().map(String::as_str) != Some("explain") {
        return Err(
            "Usage: vibeguard-runtime config explain <key-or-env> [--cwd <path>] [--json]".into(),
        );
    }
    let mut key = None;
    let mut cwd = None;
    let mut json = false;
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--cwd" if index + 1 < args.len() => {
                cwd = Some(args[index + 1].clone());
                index += 2;
            }
            "--json" => {
                json = true;
                index += 1;
            }
            value if !value.starts_with('-') && key.is_none() => {
                key = Some(value.to_string());
                index += 1;
            }
            _ => {
                return Err(
                    "Usage: vibeguard-runtime config explain <key-or-env> [--cwd <path>] [--json]"
                        .into(),
                );
            }
        }
    }
    let Some(key) = key else {
        return Err(
            "Usage: vibeguard-runtime config explain <key-or-env> [--cwd <path>] [--json]".into(),
        );
    };
    Ok(ParsedExplain { key, cwd, json })
}

struct ConfigLayers {
    user: Option<&'static Value>,
    user_path: String,
    project: Option<(Value, String)>,
}

#[derive(Clone)]
struct ProjectDocument {
    value: Value,
    path: PathBuf,
}

fn config_layers(json_path: &str, cwd: Option<&str>) -> Result<ConfigLayers, RuntimeConfigError> {
    let user = loaded_runtime_config()?.and_then(|value| value_at_path(value, json_path));
    let user_path = source_detail(&runtime_config_file(), json_path);
    let effective_cwd = resolution_cwd(cwd);
    let project = cached_project_document(effective_cwd.as_deref())?.and_then(|document| {
        value_at_path(&document.value, json_path)
            .cloned()
            .map(|value| (value, source_detail(&document.path, json_path)))
    });
    Ok(ConfigLayers {
        user,
        user_path,
        project,
    })
}

fn cached_project_document(
    cwd: Option<&str>,
) -> Result<Option<ProjectDocument>, RuntimeConfigError> {
    let current_dir = cwd
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_default();
    let selector = std::env::var("VIBEGUARD_PROJECT_CONFIG").unwrap_or_default();
    let key = format!("{}\0{selector}", current_dir.display());
    let cache = PROJECT_CONFIGS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut entries = cache.lock().map_err(|_| RuntimeConfigError {
        message: "VibeGuard runtime config cache unavailable: category=config_internal_error"
            .into(),
        exit_code: 20,
    })?;
    if let Some(cached) = entries.get(&key) {
        return cached.clone();
    }
    let loaded = project_config_path(cwd, &HashMap::new())
        .map(|path| {
            validated_project_config_json(&path)
                .map(|value| ProjectDocument { value, path })
                .map_err(project_error)
        })
        .transpose();
    entries.insert(key, loaded.clone());
    loaded
}

fn resolution_cwd(explicit: Option<&str>) -> Option<String> {
    explicit
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .or_else(|| {
            [
                "VG_INTERNAL_POLICY_CWD",
                "VIBEGUARD_POLICY_CWD",
                "VIBEGUARD_PROJECT_ROOT",
                "VIBEGUARD_PROJECT_CWD",
            ]
            .iter()
            .find_map(|name| std::env::var(name).ok().filter(|value| !value.is_empty()))
        })
}

fn resolve_field(
    field: &RuntimeConfigField,
    cwd: Option<&str>,
) -> Result<Resolved<Value>, RuntimeConfigError> {
    let env_name = field.env.unwrap_or("");
    match field.kind {
        FieldKind::Integer { .. } | FieldKind::Version => {
            resolve_int(env_name, field.path, field.default, cwd)
                .map(|value| value.map(Value::from))
        }
        FieldKind::StringEnum { .. } => resolve_str(env_name, field.path, field.default, cwd)
            .map(|value| value.map(Value::from)),
        FieldKind::StringArray { .. } => {
            resolve_list(env_name, field.path, cwd).map(|value| value.map(|items| json!(items)))
        }
    }
}

impl<T> Resolved<T> {
    fn map<U>(self, transform: impl FnOnce(T) -> U) -> Resolved<U> {
        Resolved {
            value: transform(self.value),
            source: self.source,
            detail: self.detail,
        }
    }
}

fn resolved<T>(value: T, source: ConfigSource, detail: impl Into<String>) -> Resolved<T> {
    Resolved {
        value,
        source,
        detail: detail.into(),
    }
}

fn project_error(message: String) -> RuntimeConfigError {
    RuntimeConfigError {
        message,
        exit_code: 20,
    }
}

fn source_detail(path: &Path, json_path: &str) -> String {
    format!("{}#$.{json_path}", path.display())
}

fn parse_skill_list(
    raw: &str,
    env_name: &str,
    json_path: &str,
) -> Result<Vec<String>, RuntimeConfigError> {
    if raw.is_empty() {
        return Ok(Vec::new());
    }
    raw.split(',')
        .map(str::trim)
        .map(|entry| {
            is_skill_name(entry)
                .then(|| entry.to_string())
                .ok_or_else(|| RuntimeConfigError {
                    message: format!(
                        "VibeGuard runtime config invalid: environment override {env_name}: path={json_path} category=config_value_error expected=comma_separated_skill_names"
                    ),
                    exit_code: 20,
                })
        })
        .collect()
}

fn parse_environment_int(
    raw: &str,
    env_name: &str,
    json_path: &str,
) -> Result<u64, RuntimeConfigError> {
    if !is_nonnegative_digits(raw) {
        return Err(environment_error(
            env_name,
            json_path,
            "config_type_error expected=nonnegative_integer",
        ));
    }
    let value = raw.parse::<u64>().map_err(|_| {
        environment_error(
            env_name,
            json_path,
            "config_range_error expected=unsigned_64_bit_integer",
        )
    })?;
    if let Some(field) = field_for_key(json_path)
        && let FieldKind::Integer { minimum, maximum } = field.kind
        && !(minimum..=maximum).contains(&value)
    {
        return Err(environment_error(
            env_name,
            json_path,
            &format!("config_range_error expected={minimum}..={maximum}"),
        ));
    }
    Ok(value)
}

fn validate_environment_string(
    value: &str,
    env_name: &str,
    json_path: &str,
) -> Result<(), RuntimeConfigError> {
    if let Some(field) = field_for_key(json_path)
        && let FieldKind::StringEnum { allowed } = field.kind
        && !allowed.contains(&value)
    {
        return Err(environment_error(
            env_name,
            json_path,
            &format!("config_enum_error expected={}", allowed.join("|")),
        ));
    }
    Ok(())
}

fn environment_error(env_name: &str, json_path: &str, detail: &str) -> RuntimeConfigError {
    RuntimeConfigError {
        message: format!(
            "VibeGuard runtime config invalid: environment override {env_name}: path={json_path} category={detail}"
        ),
        exit_code: 20,
    }
}

fn string_items(items: &[Value]) -> Vec<String> {
    items
        .iter()
        .filter_map(Value::as_str)
        .map(|entry| entry.trim().to_string())
        .collect()
}

fn display_value(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        _ => serde_json::to_string(value).unwrap_or_else(|_| "null".to_string()),
    }
}
