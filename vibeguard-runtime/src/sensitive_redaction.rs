use std::sync::OnceLock;

use regex::Regex;
use serde_json::Value;

const REDACTED: &str = "***REDACTED***";

fn patterns() -> &'static [Regex] {
    static PATTERNS: OnceLock<Vec<Regex>> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        [
            r#"(?i)(\bAuthorization\s*:\s*Bearer\s+)[^\s\"'`&;]+"#,
            r#"(?i)(\bBearer\s+)[^\s\"'`&;]+"#,
            r#"(?i)(\s--?(?:api[_-]?key|password|passwd|secret|token)\s+)[^\s\"'`&;]+"#,
            r#"(?i)\b([A-Za-z0-9_:-]*(?:api[_-]?key|password|passwd|secret|token)[A-Za-z0-9_:-]*\s*[:=]\s*)(\"[^\"]*\"|'[^']*'|[^\s\"'`&;]+)"#,
        ]
        .into_iter()
        .map(|pattern| Regex::new(pattern).expect("sensitive redaction regex must compile"))
        .collect()
    })
}

pub(crate) fn redact_sensitive(text: &str) -> String {
    let lower = text.to_ascii_lowercase();
    if ![
        "authorization",
        "bearer",
        "token",
        "secret",
        "password",
        "passwd",
        "api_key",
        "api-key",
        "apikey",
    ]
    .iter()
    .any(|marker| lower.contains(marker))
    {
        return text.to_string();
    }

    patterns()
        .iter()
        .fold(text.to_string(), |redacted, pattern| {
            pattern
                .replace_all(&redacted, format!("${{1}}{REDACTED}"))
                .into_owned()
        })
}

pub(crate) fn redact_sensitive_values(value: &mut Value) {
    match value {
        Value::String(text) => *text = redact_sensitive(text),
        Value::Array(values) => values.iter_mut().for_each(redact_sensitive_values),
        Value::Object(fields) => fields.values_mut().for_each(redact_sensitive_values),
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn redacts_shell_secret_forms_without_removing_context() {
        let text = "curl -H 'Authorization: Bearer bearer-value' \
                    https://example.test?api_key=query-value \
                    --token flag-value PASSWORD=assignment-value";
        let redacted = redact_sensitive(text);

        assert_eq!(
            redacted,
            "curl -H 'Authorization: Bearer ***REDACTED***' \
             https://example.test?api_key=***REDACTED*** \
             --token ***REDACTED*** PASSWORD=***REDACTED***"
        );
    }

    #[test]
    fn recursively_redacts_json_string_values_only() {
        let mut value = json!({
            "detail": "token=top-secret",
            "nested": ["Bearer nested-secret", 7, true],
            "ordinary": "cargo test"
        });

        redact_sensitive_values(&mut value);

        assert_eq!(value["detail"], "token=***REDACTED***");
        assert_eq!(value["nested"][0], "Bearer ***REDACTED***");
        assert_eq!(value["nested"][1], 7);
        assert_eq!(value["ordinary"], "cargo test");
    }
}
