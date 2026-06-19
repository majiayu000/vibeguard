use serde_json::Value;

pub(crate) const SUPPRESSION_ACTION_VALUES: &[&str] = &["downgrade_to_warn", "suppress"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScopedSuppression {
    pub hook: String,
    pub rule_id: String,
    pub path: String,
    pub code: Option<String>,
    pub action: String,
    pub reason: String,
    pub expires_at: Option<String>,
}

pub(crate) fn scoped_suppressions_from_object(
    object: &serde_json::Map<String, Value>,
) -> Vec<ScopedSuppression> {
    object
        .get("scoped_suppressions")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_object)
                .filter_map(|item| {
                    Some(ScopedSuppression {
                        hook: item.get("hook")?.as_str()?.to_string(),
                        rule_id: item.get("rule_id")?.as_str()?.to_string(),
                        path: item.get("path")?.as_str()?.to_string(),
                        code: item.get("code").and_then(Value::as_str).map(str::to_string),
                        action: item.get("action")?.as_str()?.to_string(),
                        reason: item.get("reason")?.as_str()?.to_string(),
                        expires_at: item
                            .get("expires_at")
                            .and_then(Value::as_str)
                            .map(str::to_string),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub(crate) fn validate_scoped_suppressions(
    object: &serde_json::Map<String, Value>,
    disabled_hook_values: &[String],
    errors: &mut Vec<String>,
) {
    let Some(value) = object.get("scoped_suppressions") else {
        return;
    };
    let Some(items) = value.as_array() else {
        errors.push(".scoped_suppressions: expected array".to_string());
        return;
    };

    for (index, item) in items.iter().enumerate() {
        let Some(entry) = item.as_object() else {
            errors.push(format!(".scoped_suppressions.{index}: expected object"));
            continue;
        };
        validate_entry(index, entry, disabled_hook_values, errors);
    }
}

fn validate_entry(
    index: usize,
    entry: &serde_json::Map<String, Value>,
    disabled_hook_values: &[String],
    errors: &mut Vec<String>,
) {
    for key in entry.keys() {
        if !matches!(
            key.as_str(),
            "hook" | "rule_id" | "path" | "code" | "action" | "reason" | "expires_at"
        ) {
            errors.push(format!(
                ".scoped_suppressions.{index}.{key}: unknown property"
            ));
        }
    }

    validate_required_string(entry, index, "hook", errors);
    validate_required_string(entry, index, "rule_id", errors);
    validate_required_string(entry, index, "path", errors);
    validate_required_string(entry, index, "action", errors);
    validate_required_string(entry, index, "reason", errors);

    if let Some(hook) = entry.get("hook").and_then(Value::as_str) {
        if !disabled_hook_values.iter().any(|allowed| allowed == hook) {
            errors.push(format!(
                ".scoped_suppressions.{index}.hook: unsupported hook {hook}"
            ));
        }
    }
    if let Some(rule_id) = entry.get("rule_id").and_then(Value::as_str) {
        if !valid_suppression_rule_id(rule_id) {
            errors.push(format!(
                ".scoped_suppressions.{index}.rule_id: unsupported rule id {rule_id}"
            ));
        }
    }
    if let Some(path) = entry.get("path").and_then(Value::as_str) {
        if !valid_project_path(path) {
            errors.push(format!(
                ".scoped_suppressions.{index}.path: expected project-relative path or glob"
            ));
        }
    }
    if let Some(code) = entry.get("code") {
        match code.as_str() {
            Some(text) if valid_event_code(text) => {}
            Some(text) => errors.push(format!(
                ".scoped_suppressions.{index}.code: unsupported event code {text}"
            )),
            None => errors.push(format!(
                ".scoped_suppressions.{index}.code: expected string"
            )),
        }
    }
    if let Some(action) = entry.get("action").and_then(Value::as_str) {
        if !SUPPRESSION_ACTION_VALUES
            .iter()
            .any(|allowed| allowed == &action)
        {
            errors.push(format!(
                ".scoped_suppressions.{index}.action: unsupported value {action}"
            ));
        }
    }
    if let Some(reason) = entry.get("reason").and_then(Value::as_str) {
        if reason.trim().len() < 12 {
            errors.push(format!(
                ".scoped_suppressions.{index}.reason: expected at least 12 non-empty characters"
            ));
        }
    }
    if let Some(expires_at) = entry.get("expires_at") {
        match expires_at.as_str() {
            Some(text) if valid_yyyy_mm_dd(text) => {}
            Some(text) => errors.push(format!(
                ".scoped_suppressions.{index}.expires_at: expected YYYY-MM-DD, got {text}"
            )),
            None => errors.push(format!(
                ".scoped_suppressions.{index}.expires_at: expected string"
            )),
        }
    }
}

fn validate_required_string(
    entry: &serde_json::Map<String, Value>,
    index: usize,
    field: &str,
    errors: &mut Vec<String>,
) {
    match entry.get(field) {
        Some(Value::String(text)) if !text.trim().is_empty() => {}
        Some(Value::String(_)) => errors.push(format!(
            ".scoped_suppressions.{index}.{field}: expected non-empty string"
        )),
        Some(_) => errors.push(format!(
            ".scoped_suppressions.{index}.{field}: expected string"
        )),
        None => errors.push(format!(
            ".scoped_suppressions.{index}.{field}: required field missing"
        )),
    }
}

fn valid_suppression_rule_id(rule: &str) -> bool {
    let Some((prefix, suffix)) = rule.split_once('-') else {
        return false;
    };
    if !matches!(
        prefix,
        "SEC" | "RS" | "GO" | "TS" | "PY" | "U" | "W" | "TASTE"
    ) {
        return false;
    }
    !suffix.is_empty()
        && suffix
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

fn valid_event_code(code: &str) -> bool {
    code.starts_with("VG-")
        && code
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'-')
}

fn valid_project_path(path: &str) -> bool {
    let trimmed = path.trim();
    !trimmed.is_empty()
        && !trimmed.starts_with('/')
        && !trimmed.contains('\\')
        && !trimmed.contains('\n')
        && !trimmed.split('/').any(|part| part == "..")
}

fn valid_yyyy_mm_dd(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() == 10
        && bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes
            .iter()
            .enumerate()
            .all(|(index, byte)| index == 4 || index == 7 || byte.is_ascii_digit())
}
