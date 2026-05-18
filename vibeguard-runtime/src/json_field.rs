//! JSON field extraction — replaces vg_json_field / vg_json_two_fields Python calls.
//! Reads JSON from stdin, extracts nested fields by dot-separated path.
//!
//! Contract matrix:
//!
//! | Input state | tolerant `json-field` | `json-field --strict` |
//! | --- | --- | --- |
//! | invalid JSON | exit 1 | exit 1 |
//! | absent field | print empty string, exit 0 | exit 1 |
//! | null field | print empty string, exit 0 | exit 1 |
//! | empty string field | print empty string, exit 0 | print empty string, exit 0 |
//!
//! Non-string values are printed as their JSON representation in both modes.

use serde_json::Value;
use std::io::{self, Read};

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

fn read_stdin() -> io::Result<String> {
    let mut buf = String::new();
    io::stdin().read_to_string(&mut buf)?;
    Ok(buf)
}

fn get_nested<'a>(data: &'a Value, path: &str) -> Option<&'a Value> {
    let mut val = data;
    for key in path.split('.') {
        val = match val.get(key) {
            Some(v) => v,
            None => return None,
        };
    }
    Some(val)
}

fn value_to_string(val: &Value) -> String {
    match val {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

fn parse_field_args(args: &[String]) -> std::result::Result<(bool, &str), String> {
    match args {
        [field] => Ok((false, field.as_str())),
        [flag, field] if flag == "--strict" => Ok((true, field.as_str())),
        _ => Err("Usage: vibeguard-runtime json-field [--strict] <field_path>".into()),
    }
}

/// vibeguard-runtime json-field <field_path>
/// Reads JSON from stdin, prints the field value to stdout.
pub fn run_field(args: &[String]) -> Result {
    let (strict, field_path) = parse_field_args(args)?;
    let input = read_stdin()?;
    let data: Value = serde_json::from_str(&input)?;
    let val = match get_nested(&data, field_path) {
        Some(Value::Null) if strict => return Err(format!("null field: {field_path}").into()),
        Some(v) => v,
        None if strict => return Err(format!("missing field: {field_path}").into()),
        None => &Value::Null,
    };
    println!("{}", value_to_string(val));
    Ok(())
}

/// vibeguard-runtime json-two-fields <field1> <field2>
/// Reads JSON from stdin, prints field1 on first line, field2 on remaining lines.
pub fn run_two_fields(args: &[String]) -> Result {
    if args.len() < 2 {
        return Err("Usage: vibeguard-runtime json-two-fields <field1> <field2>".into());
    }
    let input = read_stdin()?;
    let data: Value = serde_json::from_str(&input)?;
    let f1 = value_to_string(get_nested(&data, &args[0]).unwrap_or(&Value::Null));
    let f2 = value_to_string(get_nested(&data, &args[1]).unwrap_or(&Value::Null));
    println!("{f1}");
    println!("{f2}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn get_nested_follows_dot_separated_object_path() {
        let data = json!({
            "tool_input": {
                "command": "cargo test",
                "meta": {"attempt": 2}
            }
        });

        assert_eq!(
            get_nested(&data, "tool_input.command").and_then(Value::as_str),
            Some("cargo test")
        );
        assert_eq!(
            get_nested(&data, "tool_input.meta.attempt"),
            Some(&json!(2))
        );
    }

    #[test]
    fn get_nested_returns_none_for_missing_or_non_object_path() {
        let data = json!({"tool_input": {"command": "cargo test"}});

        assert!(get_nested(&data, "tool_input.file_path").is_none());
        assert!(get_nested(&data, "tool_input.command.value").is_none());
    }

    #[test]
    fn value_to_string_preserves_contract_matrix_values() {
        assert_eq!(value_to_string(&json!("")), "");
        assert_eq!(value_to_string(&Value::Null), "");
        assert_eq!(value_to_string(&json!(true)), "true");
        assert_eq!(value_to_string(&json!(["a", "b"])), "[\"a\",\"b\"]");
        assert_eq!(value_to_string(&json!({"n": 1})), "{\"n\":1}");
    }

    #[test]
    fn parse_field_args_accepts_tolerant_and_strict_forms() {
        let tolerant = vec!["tool".to_string()];
        let strict = vec!["--strict".to_string(), "tool_input.command".to_string()];

        assert_eq!(parse_field_args(&tolerant).unwrap(), (false, "tool"));
        assert_eq!(
            parse_field_args(&strict).unwrap(),
            (true, "tool_input.command")
        );
    }

    #[test]
    fn parse_field_args_rejects_missing_or_unknown_flags() {
        let missing: Vec<String> = Vec::new();
        let unknown = vec!["--lax".to_string(), "tool".to_string()];

        assert!(parse_field_args(&missing).is_err());
        assert!(parse_field_args(&unknown).is_err());
    }
}
