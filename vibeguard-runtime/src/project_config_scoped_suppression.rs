use crate::time_utils::{format_unix_secs_utc, now_unix_secs};
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

pub(crate) fn scoped_suppression_matches_output(
    suppression: &ScopedSuppression,
    hook_name: &str,
    output: &Value,
    payload: Option<&Value>,
    project_root: Option<&str>,
) -> bool {
    let today = format_unix_secs_utc(now_unix_secs());
    scoped_suppression_matches_output_at(
        suppression,
        hook_name,
        output,
        payload,
        project_root,
        &today[..10],
    )
}

fn scoped_suppression_matches_output_at(
    suppression: &ScopedSuppression,
    hook_name: &str,
    output: &Value,
    payload: Option<&Value>,
    project_root: Option<&str>,
    today: &str,
) -> bool {
    if suppression.hook != canonical_hook_name(hook_name) {
        return false;
    }
    if suppression
        .expires_at
        .as_deref()
        .is_some_and(|expires_at| expires_at < today)
    {
        return false;
    }

    let context = output_context_strings(output);
    let context_rule_ids = context_rule_ids(&context);
    if context_rule_ids
        .iter()
        .any(|rule_id| rule_id != &suppression.rule_id)
    {
        return false;
    }

    let structured_rule_id = output_string_field(output, &["rule_id", "rule"])
        .or_else(|| payload.and_then(|payload| output_string_field(payload, &["rule_id", "rule"])));
    if let Some(rule_id) = structured_rule_id.as_deref() {
        if rule_id != suppression.rule_id {
            return false;
        }
    } else if !context_rule_ids
        .iter()
        .any(|rule_id| rule_id == &suppression.rule_id)
    {
        return false;
    }

    let direct_path = output_string_field(output, &["path", "file_path", "file"]).or_else(|| {
        payload.and_then(|payload| {
            output_string_field(payload, &["path", "file_path", "file"]).or_else(|| {
                nested_string_field(payload, &["tool_input", "file_path"])
                    .or_else(|| nested_string_field(payload, &["tool_input", "path"]))
                    .or_else(|| nested_string_field(payload, &["params", "file_path"]))
                    .or_else(|| nested_string_field(payload, &["params", "path"]))
            })
        })
    });
    let path_matches = direct_path
        .as_deref()
        .is_some_and(|path| path_matches(&suppression.path, path, project_root))
        || context
            .iter()
            .any(|text| text_contains_matching_path(text, &suppression.path, project_root));
    if !path_matches {
        return false;
    };
    if let Some(code) = suppression.code.as_deref() {
        let observed_code = output_string_field(output, &["code", "event_id"]).or_else(|| {
            payload.and_then(|payload| output_string_field(payload, &["code", "event_id"]))
        });
        let context_has_code = context.iter().any(|text| text_contains_token(text, code));
        if observed_code.is_some() || context_has_code {
            return observed_code.as_deref() == Some(code) || context_has_code;
        }
    }
    true
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
    if matches!(rule.as_bytes(), [b'L', b'1'..=b'7']) {
        return true;
    }
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

fn canonical_hook_name(hook_name: &str) -> String {
    let file = std::path::Path::new(hook_name)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(hook_name);
    file.strip_suffix(".sh")
        .unwrap_or(file)
        .strip_prefix("vibeguard-")
        .unwrap_or_else(|| file.strip_suffix(".sh").unwrap_or(file))
        .replace('_', "-")
}

fn output_string_field(output: &Value, fields: &[&str]) -> Option<String> {
    fields.iter().find_map(|field| {
        output
            .get(*field)
            .and_then(Value::as_str)
            .filter(|text| !text.is_empty())
            .map(str::to_string)
    })
}

fn nested_string_field(output: &Value, path: &[&str]) -> Option<String> {
    let mut current = output;
    for key in path {
        current = current.get(*key)?;
    }
    current
        .as_str()
        .filter(|text| !text.is_empty())
        .map(str::to_string)
}

fn output_context_strings(output: &Value) -> Vec<String> {
    let mut values = Vec::new();
    for field in ["reason", "message", "systemMessage", "stopReason"] {
        if let Some(text) = output.get(field).and_then(Value::as_str) {
            values.push(text.to_string());
        }
    }
    if let Some(hook_specific) = output.get("hookSpecificOutput").and_then(Value::as_object) {
        for field in [
            "additionalContext",
            "permissionDecisionReason",
            "systemMessage",
        ] {
            if let Some(text) = hook_specific.get(field).and_then(Value::as_str) {
                values.push(text.to_string());
            }
        }
        if let Some(decision) = hook_specific.get("decision").and_then(Value::as_object)
            && let Some(message) = decision.get("message").and_then(Value::as_str)
        {
            values.push(message.to_string());
        }
    }
    values
}

fn text_contains_token(text: &str, token: &str) -> bool {
    text.split(|ch: char| !(ch.is_ascii_alphanumeric() || ch == '-'))
        .any(|part| part == token)
}

fn context_rule_ids(context: &[String]) -> Vec<String> {
    context
        .iter()
        .flat_map(|text| text.split(|ch: char| !(ch.is_ascii_alphanumeric() || ch == '-')))
        .filter(|part| valid_suppression_rule_id(part))
        .map(str::to_string)
        .collect()
}

fn text_contains_matching_path(text: &str, pattern: &str, project_root: Option<&str>) -> bool {
    text.split_whitespace()
        .map(|part| {
            part.trim_matches(|ch: char| {
                matches!(
                    ch,
                    '"' | '\'' | '`' | ',' | ';' | ':' | '(' | ')' | '[' | ']' | '{' | '}'
                )
            })
        })
        .filter(|part| part.contains('/') || part.contains('.'))
        .any(|part| path_matches(pattern, part, project_root))
}

fn path_matches(pattern: &str, path: &str, project_root: Option<&str>) -> bool {
    let normalized_pattern = normalize_relative_path(pattern);
    let normalized_path = normalize_candidate_path(path, project_root);
    if normalized_pattern == normalized_path
        || wildcard_match(&normalized_pattern, &normalized_path)
    {
        return true;
    }
    false
}

fn normalize_relative_path(path: &str) -> String {
    let normalized = path.replace('\\', "/");
    normalized
        .strip_prefix("./")
        .unwrap_or(&normalized)
        .to_string()
}

fn normalize_candidate_path(path: &str, project_root: Option<&str>) -> String {
    let normalized = normalize_relative_path(path);
    if !is_absolute_path(&normalized) {
        return normalized;
    }
    let Some(root) = project_root else {
        return normalized;
    };
    let root = normalize_relative_path(root)
        .trim_end_matches('/')
        .to_string();
    if root.is_empty() {
        return normalized;
    }
    if normalized == root {
        return String::new();
    }
    let mut roots = vec![root.clone()];
    if let Some(alias) = root.strip_prefix("/private/") {
        roots.push(format!("/{alias}"));
    } else if root.starts_with('/') {
        roots.push(format!("/private{root}"));
    }
    for root in roots {
        if normalized == root {
            return String::new();
        }
        if let Some(relative) = normalized.strip_prefix(&format!("{root}/")) {
            return relative.to_string();
        }
    }
    normalized
}

fn is_absolute_path(path: &str) -> bool {
    path.starts_with('/')
        || path.starts_with("//")
        || path
            .as_bytes()
            .get(1..3)
            .is_some_and(|bytes| bytes[0] == b':' && bytes[1] == b'/')
}

fn wildcard_match(pattern: &str, text: &str) -> bool {
    wildcard_match_at(pattern.as_bytes(), text.as_bytes(), 0, 0)
}

fn wildcard_match_at(pattern: &[u8], text: &[u8], pattern_index: usize, text_index: usize) -> bool {
    if pattern_index == pattern.len() {
        return text_index == text.len();
    }
    if pattern[pattern_index] != b'*' {
        return text_index < text.len()
            && pattern[pattern_index] == text[text_index]
            && wildcard_match_at(pattern, text, pattern_index + 1, text_index + 1);
    }

    let crosses_segments = pattern_index + 1 < pattern.len() && pattern[pattern_index + 1] == b'*';
    let next_pattern_index = if crosses_segments {
        pattern_index + 2
    } else {
        pattern_index + 1
    };
    let mut candidate = text_index;
    loop {
        if wildcard_match_at(pattern, text, next_pattern_index, candidate) {
            return true;
        }
        if candidate == text.len() || (!crosses_segments && text[candidate] == b'/') {
            return false;
        }
        candidate += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ScopedSuppression, path_matches, scoped_suppression_matches_output_at,
        valid_suppression_rule_id,
    };
    use serde_json::json;

    fn suppression() -> ScopedSuppression {
        ScopedSuppression {
            hook: "post-edit-guard".to_string(),
            rule_id: "RS-03".to_string(),
            path: "docs/examples/**".to_string(),
            code: None,
            action: "suppress".to_string(),
            reason: "Known documentation example false positive".to_string(),
            expires_at: None,
        }
    }

    #[test]
    fn matches_top_level_output_fields() {
        let output = json!({
            "rule_id": "RS-03",
            "path": "docs/examples/basic.rs",
            "decision": "block"
        });

        assert!(scoped_suppression_matches_output_at(
            &suppression(),
            "post-edit-guard.sh",
            &output,
            None,
            None,
            "2026-06-19",
        ));
    }

    #[test]
    fn valid_rule_id_accepts_layer_tokens() {
        assert!(valid_suppression_rule_id("L1"));
        assert!(valid_suppression_rule_id("L7"));
        assert!(!valid_suppression_rule_id("L0"));
        assert!(!valid_suppression_rule_id("L8"));
        assert!(!valid_suppression_rule_id("L1-extra"));
    }

    #[test]
    fn matches_real_posttool_context_with_payload_path() {
        let output = json!({
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": "VIBEGUARD quality warning: [RS-03] [review] [this-edit] OBSERVATION: 1 new unwrap()/expect() call(s) added"
            }
        });
        let payload = json!({
            "hook_event_name": "PostToolUse",
            "tool_input": {
                "file_path": "/repo/docs/examples/basic.rs"
            }
        });

        assert!(scoped_suppression_matches_output_at(
            &suppression(),
            "vibeguard-post-edit-guard.sh",
            &output,
            Some(&payload),
            Some("/repo"),
            "2026-06-19",
        ));
    }

    #[test]
    fn rejects_nonmatching_payload_path() {
        let output = json!({
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": "VIBEGUARD quality warning: [RS-03] unwrap"
            }
        });
        let payload = json!({"tool_input": {"file_path": "/repo/src/main.rs"}});

        assert!(!scoped_suppression_matches_output_at(
            &suppression(),
            "post-edit-guard.sh",
            &output,
            Some(&payload),
            Some("/repo"),
            "2026-06-19",
        ));
    }

    #[test]
    fn rejects_aggregate_context_with_other_rule_ids() {
        let output = json!({
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": "VIBEGUARD quality warning: [RS-03] unwrap and [W-15] repeated edit"
            }
        });
        let payload = json!({"tool_input": {"file_path": "/repo/docs/examples/basic.rs"}});

        assert!(!scoped_suppression_matches_output_at(
            &suppression(),
            "post-edit-guard.sh",
            &output,
            Some(&payload),
            Some("/repo"),
            "2026-06-19",
        ));
    }

    #[test]
    fn structured_rule_id_overrides_context_rule_mentions() {
        let output = json!({
            "rule_id": "RS-10",
            "path": "docs/examples/basic.rs",
            "reason": "Mentions [RS-03] as related background",
        });

        assert!(!scoped_suppression_matches_output_at(
            &suppression(),
            "post-edit-guard.sh",
            &output,
            None,
            None,
            "2026-06-19",
        ));
    }

    #[test]
    fn requires_matching_optional_code() {
        let output = json!({
            "rule_id": "RS-03",
            "path": "docs/examples/basic.rs",
            "code": "VG-POLICY-RS03-DOC-EXAMPLE"
        });
        let mut scoped = suppression();
        scoped.code = Some("VG-POLICY-RS03-DOC-EXAMPLE".to_string());

        assert!(scoped_suppression_matches_output_at(
            &scoped,
            "post-edit-guard.sh",
            &output,
            None,
            None,
            "2026-06-19",
        ));

        scoped.code = Some("VG-POLICY-OTHER".to_string());
        assert!(!scoped_suppression_matches_output_at(
            &scoped,
            "post-edit-guard.sh",
            &output,
            None,
            None,
            "2026-06-19",
        ));

        let output_without_code = json!({
            "rule_id": "RS-03",
            "path": "docs/examples/basic.rs"
        });
        scoped.code = Some("VG-POLICY-RS03-DOC-EXAMPLE".to_string());
        assert!(scoped_suppression_matches_output_at(
            &scoped,
            "post-edit-guard.sh",
            &output_without_code,
            None,
            None,
            "2026-06-19",
        ));
    }

    #[test]
    fn ignores_expired_suppressions() {
        let output = json!({
            "rule_id": "RS-03",
            "path": "docs/examples/basic.rs",
        });
        let mut scoped = suppression();
        scoped.expires_at = Some("2026-01-01".to_string());

        assert!(!scoped_suppression_matches_output_at(
            &scoped,
            "post-edit-guard.sh",
            &output,
            None,
            None,
            "2026-06-19",
        ));

        scoped.expires_at = Some("2026-06-19".to_string());
        assert!(scoped_suppression_matches_output_at(
            &scoped,
            "post-edit-guard.sh",
            &output,
            None,
            None,
            "2026-06-19",
        ));
    }

    #[test]
    fn single_star_path_patterns_do_not_cross_segments() {
        assert!(path_matches("docs/*.rs", "docs/basic.rs", None));
        assert!(!path_matches("docs/*.rs", "docs/examples/basic.rs", None));
        assert!(path_matches("docs/**/*.rs", "docs/examples/basic.rs", None));
    }

    #[test]
    fn absolute_paths_match_only_inside_project_root() {
        assert!(path_matches(
            "docs/examples/**",
            "/repo/docs/examples/basic.rs",
            Some("/repo"),
        ));
        assert!(!path_matches(
            "docs/examples/**",
            "/repo/third_party/docs/examples/basic.rs",
            Some("/repo"),
        ));
        assert!(!path_matches(
            "docs/examples/**",
            "/other/docs/examples/basic.rs",
            Some("/repo"),
        ));
        assert!(path_matches(
            "docs/examples/**",
            "/var/folders/repo/docs/examples/basic.rs",
            Some("/private/var/folders/repo"),
        ));
    }
}
