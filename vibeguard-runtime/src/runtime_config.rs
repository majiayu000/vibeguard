use serde_json::Value;

pub fn get_int(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    if args.len() < 3 || args.len() > 4 {
        return Err(
            "runtime-config-get-int requires <env-name> <json-path> <default> [config-file]".into(),
        );
    }
    let env_name = &args[0];
    let json_path = &args[1];
    let default_value = &args[2];
    let config_file = args.get(3).map(String::as_str).unwrap_or("");

    if let Ok(value) = std::env::var(env_name) {
        if is_unsigned_integer(&value) {
            println!("{value}");
            return Ok(());
        }
    }

    if let Some(value) = read_config_value(config_file, json_path) {
        if let Some(number) = value.as_i64().filter(|number| *number >= 0) {
            println!("{number}");
            return Ok(());
        }
    }

    println!("{default_value}");
    Ok(())
}

pub fn get_str(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    if args.len() < 3 || args.len() > 4 {
        return Err(
            "runtime-config-get-str requires <env-name> <json-path> <default> [config-file]".into(),
        );
    }
    let env_name = &args[0];
    let json_path = &args[1];
    let default_value = &args[2];
    let config_file = args.get(3).map(String::as_str).unwrap_or("");

    if let Ok(value) = std::env::var(env_name) {
        if !value.is_empty() {
            println!("{value}");
            return Ok(());
        }
    }

    if let Some(value) = read_config_value(config_file, json_path) {
        if let Some(text) = value.as_str().filter(|text| !text.is_empty()) {
            println!("{text}");
            return Ok(());
        }
    }

    println!("{default_value}");
    Ok(())
}

fn read_config_value(config_file: &str, json_path: &str) -> Option<Value> {
    if config_file.is_empty() {
        return None;
    }
    let text = std::fs::read_to_string(config_file).ok()?;
    let mut value = serde_json::from_str::<Value>(&text).ok()?;
    for key in json_path.split('.') {
        value = value.as_object()?.get(key)?.clone();
    }
    Some(value)
}

fn is_unsigned_integer(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unsigned_integer_rejects_empty_and_signed_values() {
        assert!(is_unsigned_integer("0"));
        assert!(is_unsigned_integer("123"));
        assert!(!is_unsigned_integer(""));
        assert!(!is_unsigned_integer("-1"));
    }
}
