use serde_json::Value;

const SENSITIVE_KEYS: &[&str] = &[
    "prompt",
    "command",
    "cmd",
    "cwd",
    "path",
    "file",
    "diff",
    "response",
    "output",
    "input",
    "token",
    "authorization",
    "secret",
    "password",
];

pub fn redact_value(value: &Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(key, value)| {
                    if is_sensitive_key(key) {
                        (key.clone(), Value::String("[REDACTED]".to_owned()))
                    } else {
                        (key.clone(), redact_value(value))
                    }
                })
                .collect(),
        ),
        Value::Array(values) => Value::Array(values.iter().map(redact_value).collect()),
        _ => value.clone(),
    }
}

fn is_sensitive_key(key: &str) -> bool {
    let normalized = key.to_ascii_lowercase();
    SENSITIVE_KEYS
        .iter()
        .any(|candidate| normalized == *candidate || normalized.ends_with(candidate))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn recursively_redacts_sensitive_fields() {
        let input = json!({
            "sessionId": "safe",
            "payload": {
                "command": "rm something",
                "nested": [{"filePath": "/private/path", "status": "working"}]
            }
        });
        let redacted = redact_value(&input);
        assert_eq!(redacted["sessionId"], "safe");
        assert_eq!(redacted["payload"]["command"], "[REDACTED]");
        assert_eq!(redacted["payload"]["nested"][0]["filePath"], "[REDACTED]");
        assert_eq!(redacted["payload"]["nested"][0]["status"], "working");
    }
}
