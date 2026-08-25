use std::sync::OnceLock;

use regex::Regex;
use serde_json::Value;

const REDACTED: &str = "***REDACTED***";

fn patterns() -> &'static [Regex] {
    static PATTERNS: OnceLock<Vec<Regex>> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        [
            r#"(?i)(\bAuthorization\s*:\s*[A-Za-z][A-Za-z0-9_-]*\s+)[^\s\"'`&;]+"#,
            r#"(?i)(\bBearer\s+)[^\s\"'`&;]+"#,
            r#"(?i)(\s--?(?:api[_-]?key|password|passwd|secret|token)\s+)[^\s\"'`&;]+"#,
            r#"(?i)\b([A-Za-z0-9_:-]*(?:api[_-]?key|password|passwd|secret|token)[A-Za-z0-9_:-]*\s*[:=]\s*)(\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^\s\"'`&;]+)"#,
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
        Value::Object(fields) => fields.iter_mut().for_each(|(key, value)| {
            if sensitive_key(key) {
                *value = Value::String(REDACTED.to_string());
            } else {
                redact_sensitive_values(value);
            }
        }),
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}

fn sensitive_key(key: &str) -> bool {
    let normalized = key
        .chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect::<String>();

    normalized == "authorization"
        || normalized.ends_with("apikey")
        || normalized.ends_with("password")
        || normalized.ends_with("passwd")
        || normalized.ends_with("secret")
        || normalized.ends_with("token")
        || normalized.ends_with("credential")
        || normalized.ends_with("credentials")
        || normalized.ends_with("privatekey")
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
            "token": "opaque-token-value",
            "client_secret": "opaque-client-secret",
            "authorization": {"scheme": "Basic", "value": "opaque-auth-value"},
            "credentials": {"user": "fixture", "value": "opaque-credential-value"},
            "ssh_private_key": ["opaque-private-key"],
            "retry_token": 7,
            "token_count": "ordinary-count-label",
            "ordinary": "cargo test"
        });

        redact_sensitive_values(&mut value);

        assert_eq!(value["detail"], "token=***REDACTED***");
        assert_eq!(value["nested"][0], "Bearer ***REDACTED***");
        assert_eq!(value["nested"][1], 7);
        assert_eq!(value["token"], "***REDACTED***");
        assert_eq!(value["client_secret"], "***REDACTED***");
        assert_eq!(value["authorization"], "***REDACTED***");
        assert_eq!(value["credentials"], "***REDACTED***");
        assert_eq!(value["ssh_private_key"], "***REDACTED***");
        assert_eq!(value["retry_token"], "***REDACTED***");
        assert_eq!(value["token_count"], "ordinary-count-label");
        assert_eq!(value["ordinary"], "cargo test");
    }

    #[test]
    fn redacts_basic_authorization_headers() {
        assert_eq!(
            redact_sensitive("Authorization: Basic Zml4dHVyZTpwYXNzd29yZA=="),
            "Authorization: Basic ***REDACTED***"
        );
    }

    #[test]
    fn redacts_quoted_credentials_with_escaped_quotes() {
        let text = r#"password="abc\"def secret" token='ghi\'jkl secret'"#;

        assert_eq!(
            redact_sensitive(text),
            "password=***REDACTED*** token=***REDACTED***"
        );
    }
}
