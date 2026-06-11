//! Typed config extraction for hook runtime settings.
//!
//! This keeps hot-path hook config reads on the Rust runtime when available.
//! Missing files, malformed JSON, missing keys, and wrong types return non-zero;
//! shell callers decide whether to fall back to a documented default.

use crate::json_field::get_nested;
use serde_json::Value;
use std::fs;

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

fn typed_value_to_string(kind: &str, val: &Value) -> std::result::Result<String, String> {
    match kind {
        "int" => val
            .as_u64()
            .map(|n| n.to_string())
            .ok_or_else(|| "value is not a non-negative integer".to_string()),
        "string" => val
            .as_str()
            .map(ToString::to_string)
            .ok_or_else(|| "value is not a string".to_string()),
        _ => Err("type must be int or string".to_string()),
    }
}

/// vibeguard-runtime config-get <int|string> <config-file> <field_path>
pub fn run_get(args: &[String]) -> Result {
    if args.len() != 3 {
        return Err(
            "Usage: vibeguard-runtime config-get <int|string> <config-file> <field_path>".into(),
        );
    }

    let kind = args[0].as_str();
    let text = fs::read_to_string(&args[1])?;
    let data: Value = serde_json::from_str(&text)?;
    let val = get_nested(&data, &args[2]).ok_or_else(|| format!("missing field: {}", args[2]))?;
    let out = typed_value_to_string(kind, val)?;
    println!("{out}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn config_get_reuses_shared_dot_path_reader() {
        let data = json!({"u16": {"limit": 1234}});
        assert_eq!(get_nested(&data, "u16.limit"), Some(&json!(1234)));
        assert_eq!(get_nested(&data, "missing.limit"), None);
    }

    #[test]
    fn typed_value_to_string_enforces_expected_types() {
        assert_eq!(typed_value_to_string("int", &json!(1234)).unwrap(), "1234");
        assert_eq!(
            typed_value_to_string("string", &json!("block")).unwrap(),
            "block"
        );
        assert!(typed_value_to_string("int", &json!(-1)).is_err());
        assert!(typed_value_to_string("int", &json!(true)).is_err());
        assert!(typed_value_to_string("string", &json!(1234)).is_err());
    }
}
