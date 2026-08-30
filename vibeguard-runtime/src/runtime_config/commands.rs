use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::HandlerResult;
use crate::git_root::git_root_for;
use crate::project_config::{
    project_config_path, validate_project_config_value, validated_project_config_json,
};
use crate::runtime_config::fields::{
    FieldKind, RUNTIME_CONFIG_FIELDS, RuntimeConfigField, field_for_key,
};
use crate::runtime_config::resolution;
use crate::runtime_config::validation::{RuntimeConfigDecision, validate_runtime_config_overlay};
use crate::setup::support::write_json_atomic;
#[cfg(unix)]
use crate::setup::support::write_json_atomic_private;

use super::{is_nonnegative_digits, runtime_config_file};

const SHOW_USAGE: &str = "Usage: vibeguard-runtime config show [--cwd <path>] [--json]";
const INIT_USAGE: &str = "Usage: vibeguard-runtime config init --scope user|project [--cwd <path>]";
const SET_USAGE: &str =
    "Usage: vibeguard-runtime config set <key> <value> --scope user|project [--cwd <path>]";
const RESET_USAGE: &str =
    "Usage: vibeguard-runtime config reset <key> --scope user|project [--cwd <path>]";

type CommandResult<T> = Result<T, String>;

#[derive(Clone, Copy)]
enum Scope {
    User,
    Project,
}

enum EditableField {
    Runtime(&'static RuntimeConfigField),
    Profile,
    Enforcement,
    Languages,
}

pub(super) fn run(args: &[String]) -> HandlerResult {
    match args.first().map(String::as_str) {
        Some("show") => {
            let (cwd, json_output) = parse_show_args(&args[1..])?;
            show(cwd.as_deref(), json_output)
        }
        Some("init") => {
            let (scope, cwd) = parse_scope_and_cwd(&args[1..], 0, INIT_USAGE)?;
            init(scope, cwd.as_deref()).map_err(Into::into)
        }
        Some("set") => {
            if args.len() < 4 {
                return Err(SET_USAGE.into());
            }
            let key = &args[1];
            let value = &args[2];
            let (scope, cwd) = parse_scope_and_cwd(&args[3..], 0, SET_USAGE)?;
            set(scope, key, value, cwd.as_deref()).map_err(Into::into)
        }
        Some("reset") => {
            if args.len() < 3 {
                return Err(RESET_USAGE.into());
            }
            let key = &args[1];
            let (scope, cwd) = parse_scope_and_cwd(&args[2..], 0, RESET_USAGE)?;
            reset(scope, key, cwd.as_deref()).map_err(Into::into)
        }
        _ => Err(format!("{SHOW_USAGE}\n{INIT_USAGE}\n{SET_USAGE}\n{RESET_USAGE}").into()),
    }
}

fn parse_show_args(args: &[String]) -> CommandResult<(Option<String>, bool)> {
    let mut cwd = None;
    let mut json_output = false;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--cwd" if index + 1 < args.len() => {
                cwd = Some(args[index + 1].clone());
                index += 2;
            }
            "--json" => {
                json_output = true;
                index += 1;
            }
            _ => return Err(SHOW_USAGE.to_string()),
        }
    }
    Ok((cwd, json_output))
}

fn parse_scope_and_cwd(
    args: &[String],
    start: usize,
    usage: &str,
) -> CommandResult<(Scope, Option<String>)> {
    let mut scope = None;
    let mut cwd = None;
    let mut index = start;
    while index < args.len() {
        match args[index].as_str() {
            "--scope" if index + 1 < args.len() => {
                scope = Some(match args[index + 1].as_str() {
                    "user" => Scope::User,
                    "project" => Scope::Project,
                    _ => return Err(usage.to_string()),
                });
                index += 2;
            }
            "--cwd" if index + 1 < args.len() => {
                cwd = Some(args[index + 1].clone());
                index += 2;
            }
            _ => return Err(usage.to_string()),
        }
    }
    scope
        .map(|scope| (scope, cwd))
        .ok_or_else(|| usage.to_string())
}

fn show(cwd: Option<&str>, json_output: bool) -> HandlerResult {
    resolution::resolve_effective_churn_thresholds(cwd, None).map_err(|error| error.message)?;
    let mut records = Vec::with_capacity(RUNTIME_CONFIG_FIELDS.len());
    for field in RUNTIME_CONFIG_FIELDS {
        let resolved = resolution::resolve_field(field, cwd).map_err(|error| error.message)?;
        records.push(json!({
            "key": field.path,
            "value": resolved.value,
            "source": resolved.source.source_name(),
            "source_detail": resolved.detail,
            "environment": field.env,
            "category": field.category,
            "description": field.description,
        }));
    }

    if json_output {
        println!(
            "{}",
            serde_json::to_string_pretty(&records).map_err(|error| error.to_string())?
        );
    } else {
        for record in records {
            println!(
                "{}: value={} source={} category={} description={}",
                record["key"].as_str().unwrap_or(""),
                resolution::display_value(&record["value"]),
                record["source"].as_str().unwrap_or(""),
                record["category"].as_str().unwrap_or(""),
                record["description"].as_str().unwrap_or("")
            );
        }
    }
    Ok(())
}

fn init(scope: Scope, cwd: Option<&str>) -> CommandResult<()> {
    let path = target_path(scope, cwd)?;
    match fs::symlink_metadata(&path) {
        Ok(_) => {
            return Err(format!(
                "cannot initialize config: target already exists: {}",
                path.display()
            ));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(path_error(&path, "inspect", error)),
    }

    let parent = config_parent(&path);
    fs::create_dir_all(parent).map_err(|error| path_error(&path, "create parent", error))?;
    match scope {
        Scope::User => write_new_user_json(&path, &json!({"version": 1}))?,
        Scope::Project => write_new_project_json(&path, &json!({"version": 1}))?,
    }
    println!("initialized path={}", path.display());
    Ok(())
}

fn set(scope: Scope, key: &str, raw_value: &str, cwd: Option<&str>) -> CommandResult<()> {
    let field = editable_field(scope, key)?;
    let value = parse_value(&field, key, raw_value)?;
    let path = target_path(scope, cwd)?;
    let mut document = load_document(scope, &path)?.unwrap_or_else(|| json!({}));
    set_json_path(&mut document, key, value)?;
    validate_candidate(scope, &path, &document, cwd)?;
    write_candidate(scope, &path, &document)?;
    println!("set key={key} path={}", path.display());
    Ok(())
}

fn reset(scope: Scope, key: &str, cwd: Option<&str>) -> CommandResult<()> {
    let _field = editable_field(scope, key)?;
    let path = target_path(scope, cwd)?;
    let Some(mut document) = load_document(scope, &path)? else {
        println!("reset key={key} path={} unchanged=true", path.display());
        return Ok(());
    };
    if !remove_json_path(&mut document, key) {
        println!("reset key={key} path={} unchanged=true", path.display());
        return Ok(());
    }
    validate_candidate(scope, &path, &document, cwd)?;
    write_candidate(scope, &path, &document)?;
    println!("reset key={key} path={}", path.display());
    Ok(())
}

fn editable_field(scope: Scope, key: &str) -> CommandResult<EditableField> {
    if let Some(field) = field_for_key(key).filter(|field| field.path == key) {
        return Ok(EditableField::Runtime(field));
    }
    if matches!(scope, Scope::Project) {
        return match key {
            "profile" => Ok(EditableField::Profile),
            "enforcement" => Ok(EditableField::Enforcement),
            "languages" => Ok(EditableField::Languages),
            _ => Err(format!(
                "unknown config key {key}; use a supported JSON path"
            )),
        };
    }
    Err(format!(
        "unknown user config key {key}; user scope accepts registered runtime JSON paths only"
    ))
}

fn parse_value(field: &EditableField, key: &str, raw_value: &str) -> CommandResult<Value> {
    match field {
        EditableField::Runtime(field) => match field.kind {
            FieldKind::Integer { minimum, maximum } => {
                let value = parse_decimal_integer(key, raw_value)?;
                if !(minimum..=maximum).contains(&value) {
                    return Err(command_error(
                        key,
                        "config_range_error",
                        &format!("integer_range={minimum}..={maximum}"),
                    ));
                }
                Ok(Value::from(value))
            }
            FieldKind::Version => {
                let value = parse_decimal_integer(key, raw_value)?;
                if value != 1 {
                    return Err(command_error(
                        key,
                        "config_version_error",
                        "supported_version=1",
                    ));
                }
                Ok(Value::from(value))
            }
            FieldKind::StringEnum { allowed } => {
                if !allowed.contains(&raw_value) {
                    return Err(command_error(
                        key,
                        "config_enum_error",
                        &format!("allowed={}", allowed.join("|")),
                    ));
                }
                Ok(Value::String(raw_value.to_string()))
            }
            FieldKind::StringArray { maximum_items } => parse_string_array(
                key,
                raw_value,
                Some(maximum_items),
                field.path == "disabled_skills",
            ),
        },
        EditableField::Profile | EditableField::Enforcement => {
            Ok(Value::String(raw_value.to_string()))
        }
        EditableField::Languages => parse_string_array(key, raw_value, None, false),
    }
}

fn parse_decimal_integer(key: &str, raw_value: &str) -> CommandResult<u64> {
    if !is_nonnegative_digits(raw_value) {
        return Err(command_error(
            key,
            "config_type_error",
            "decimal_nonnegative_integer",
        ));
    }
    raw_value
        .parse::<u64>()
        .map_err(|_| command_error(key, "config_range_error", "unsigned_64_bit_integer"))
}

fn parse_string_array(
    key: &str,
    raw_value: &str,
    maximum_items: Option<usize>,
    skills: bool,
) -> CommandResult<Value> {
    if raw_value.is_empty() {
        return Ok(Value::Array(Vec::new()));
    }
    let items = raw_value
        .split(',')
        .map(str::trim)
        .map(str::to_string)
        .collect::<Vec<_>>();
    if items.iter().any(String::is_empty) {
        return Err(command_error(
            key,
            "config_type_error",
            "comma_separated_strings_or_empty",
        ));
    }
    if maximum_items.is_some_and(|maximum| items.len() > maximum) {
        return Err(command_error(key, "config_range_error", "array_max_items"));
    }
    if skills
        && items
            .iter()
            .any(|item| !super::validation::is_skill_name(item))
    {
        return Err(command_error(key, "config_value_error", "skill_name"));
    }
    Ok(Value::Array(items.into_iter().map(Value::String).collect()))
}

fn command_error(key: &str, category: &str, expected: &str) -> String {
    format!("VibeGuard config command invalid: key={key} category={category} expected={expected}")
}

fn target_path(scope: Scope, cwd: Option<&str>) -> CommandResult<PathBuf> {
    match scope {
        Scope::User => Ok(runtime_config_file()),
        Scope::Project => project_target_path(cwd),
    }
}

fn project_target_path(cwd: Option<&str>) -> CommandResult<PathBuf> {
    if let Some(configured) = std::env::var("VIBEGUARD_PROJECT_CONFIG")
        .ok()
        .filter(|value| !value.is_empty())
    {
        return Ok(PathBuf::from(configured));
    }

    let effective_cwd = resolution::resolution_cwd(cwd);
    if let Some(path) = project_config_path(effective_cwd.as_deref(), &HashMap::new()) {
        return Ok(path);
    }
    let cwd_path = effective_cwd
        .as_deref()
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .ok_or_else(|| {
            "cannot resolve project config path: current directory unavailable".to_string()
        })?;
    if let Some(git_root) = git_root_for(&cwd_path) {
        return Ok(git_root.join(".vibeguard.json"));
    }
    Ok(cwd_path.join(".vibeguard.json"))
}

fn load_document(scope: Scope, path: &Path) -> CommandResult<Option<Value>> {
    match scope {
        Scope::User => {
            let path_text = path.to_string_lossy();
            let (decision, document) = super::validation::classify_runtime_config_file(&path_text)
                .map_err(|error| error.message)?;
            match decision {
                RuntimeConfigDecision::Missing => Ok(None),
                RuntimeConfigDecision::Valid => document
                    .ok_or_else(|| "runtime config validator returned no document".to_string())
                    .map(Some),
            }
        }
        Scope::Project => match fs::symlink_metadata(path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(path_error(path, "inspect", error)),
            Ok(_) => validated_project_config_json(path)
                .map(Some)
                .map_err(|error| error.to_string()),
        },
    }
}

fn validate_candidate(
    scope: Scope,
    path: &Path,
    candidate: &Value,
    cwd: Option<&str>,
) -> CommandResult<()> {
    match scope {
        Scope::User => {
            validate_runtime_config_overlay(path, candidate).map_err(|error| error.message)
        }
        Scope::Project => validate_project_config_value(path, candidate),
    }?;
    let effective_candidate = match scope {
        Scope::User => resolution::EffectiveCandidate::User(candidate),
        Scope::Project => resolution::EffectiveCandidate::Project(candidate),
    };
    resolution::resolve_effective_churn_thresholds(cwd, Some(effective_candidate))
        .map(|_| ())
        .map_err(|error| error.message)
}

fn write_candidate(scope: Scope, path: &Path, candidate: &Value) -> CommandResult<()> {
    let result = match scope {
        Scope::User => write_user_json_atomic(path, candidate),
        Scope::Project => write_json_atomic(path, candidate),
    };
    result.map_err(|error| path_error(path, "atomically replace", error))
}

#[cfg(unix)]
fn write_user_json_atomic(
    path: &Path,
    candidate: &Value,
) -> crate::setup::support::SetupResult<()> {
    write_json_atomic_private(path, candidate)
}

#[cfg(not(unix))]
fn write_user_json_atomic(
    path: &Path,
    candidate: &Value,
) -> crate::setup::support::SetupResult<()> {
    write_json_atomic(path, candidate)
}

fn set_json_path(document: &mut Value, path: &str, value: Value) -> CommandResult<()> {
    let parts = path.split('.').collect::<Vec<_>>();
    let Some(last) = parts.last().copied() else {
        return Err("config key cannot be empty".to_string());
    };
    let mut node = document;
    for part in &parts[..parts.len() - 1] {
        let object = node
            .as_object_mut()
            .ok_or_else(|| format!("cannot set {path}: parent is not an object"))?;
        node = object
            .entry((*part).to_string())
            .or_insert_with(|| Value::Object(Map::new()));
    }
    node.as_object_mut()
        .ok_or_else(|| format!("cannot set {path}: parent is not an object"))?
        .insert(last.to_string(), value);
    Ok(())
}

fn remove_json_path(document: &mut Value, path: &str) -> bool {
    let parts = path.split('.').collect::<Vec<_>>();
    remove_json_parts(document, &parts)
}

fn remove_json_parts(document: &mut Value, parts: &[&str]) -> bool {
    let Some(first) = parts.first().copied() else {
        return false;
    };
    let Some(object) = document.as_object_mut() else {
        return false;
    };
    if parts.len() == 1 {
        return object.remove(first).is_some();
    }
    let changed = object
        .get_mut(first)
        .is_some_and(|child| remove_json_parts(child, &parts[1..]));
    if changed
        && object
            .get(first)
            .and_then(Value::as_object)
            .is_some_and(Map::is_empty)
    {
        object.remove(first);
    }
    changed
}

fn config_parent(path: &Path) -> &Path {
    path.parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."))
}

fn write_new_user_json(path: &Path, value: &Value) -> CommandResult<()> {
    let mut options = new_json_options();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    write_new_json_with_options(path, value, options)
}

fn write_new_project_json(path: &Path, value: &Value) -> CommandResult<()> {
    write_new_json_with_options(path, value, new_json_options())
}

fn new_json_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    options
}

fn write_new_json_with_options(
    path: &Path,
    value: &Value,
    options: OpenOptions,
) -> CommandResult<()> {
    let mut bytes = serde_json::to_vec_pretty(value).map_err(|error| error.to_string())?;
    bytes.push(b'\n');
    let mut created = false;
    let result = (|| {
        let mut file = options
            .open(path)
            .map_err(|error| path_error(path, "create", error))?;
        created = true;
        file.write_all(&bytes)
            .map_err(|error| path_error(path, "write", error))?;
        file.sync_all()
            .map_err(|error| path_error(path, "sync", error))?;
        Ok::<(), String>(())
    })();
    if let Err(error) = result {
        if created
            && let Err(cleanup_error) = fs::remove_file(path)
            && cleanup_error.kind() != std::io::ErrorKind::NotFound
        {
            return Err(format!("{error}; cleanup failed: {cleanup_error}"));
        }
        return Err(error);
    }
    Ok(())
}

fn path_error(path: &Path, operation: &str, error: impl std::fmt::Display) -> String {
    format!(
        "VibeGuard config command could not {operation} {}: {error}",
        path.display()
    )
}
