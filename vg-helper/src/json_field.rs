//! JSON field extraction — replaces vg_json_field / vg_json_two_fields Python calls.
//! Reads JSON from stdin, extracts nested fields by dot-separated path.

use serde_json::Value;
use std::io::{self, Read};

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

fn read_stdin() -> io::Result<String> {
    let mut buf = String::new();
    io::stdin().read_to_string(&mut buf)?;
    Ok(buf)
}

fn get_nested<'a>(data: &'a Value, path: &str) -> &'a Value {
    let mut val = data;
    for key in path.split('.') {
        val = match val.get(key) {
            Some(v) => v,
            None => return &Value::Null,
        };
    }
    val
}

fn value_to_string(val: &Value) -> String {
    match val {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

/// vg-helper json-field <field_path>
/// Reads JSON from stdin, prints the field value to stdout.
pub fn run_field(args: &[String]) -> Result {
    if args.is_empty() {
        return Err("Usage: vg-helper json-field <field_path>".into());
    }
    let input = read_stdin()?;
    let data: Value = serde_json::from_str(&input).unwrap_or(Value::Null);
    let val = get_nested(&data, &args[0]);
    println!("{}", value_to_string(val));
    Ok(())
}

/// vg-helper json-two-fields <field1> <field2>
/// Reads JSON from stdin, prints field1 on first line, field2 on remaining lines.
pub fn run_two_fields(args: &[String]) -> Result {
    if args.len() < 2 {
        return Err("Usage: vg-helper json-two-fields <field1> <field2>".into());
    }
    let input = read_stdin()?;
    let data: Value = serde_json::from_str(&input).unwrap_or(Value::Null);
    let f1 = value_to_string(get_nested(&data, &args[0]));
    let f2 = value_to_string(get_nested(&data, &args[1]));
    println!("{f1}");
    println!("{f2}");
    Ok(())
}
