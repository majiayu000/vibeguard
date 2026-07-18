use super::*;
use serde_json::json;
use std::collections::BTreeSet;

fn schema_leaf_paths(value: &Value, prefix: &str, paths: &mut BTreeSet<String>) {
    let properties = value["properties"]
        .as_object()
        .expect("schema object should have properties");
    for (key, child) in properties {
        let path = if prefix.is_empty() {
            key.to_string()
        } else {
            format!("{prefix}.{key}")
        };
        if child["type"] == "object" {
            schema_leaf_paths(child, &path, paths);
        } else {
            paths.insert(path);
        }
    }
}

fn value_leaf_paths(value: &Value, prefix: &str, paths: &mut BTreeSet<String>) {
    for (key, child) in value.as_object().expect("template should be an object") {
        let path = if prefix.is_empty() {
            key.to_string()
        } else {
            format!("{prefix}.{key}")
        };
        if child.is_object() {
            value_leaf_paths(child, &path, paths);
        } else {
            paths.insert(path);
        }
    }
}

fn schema_at_path<'a>(schema: &'a Value, path: &str) -> &'a Value {
    let mut node = schema;
    for key in path.split('.') {
        node = &node["properties"][key];
    }
    node
}

#[test]
fn runtime_config_inventory_matches_schema_and_template() {
    let schema: Value = serde_json::from_str(include_str!(
        "../../schemas/vibeguard-runtime-config.schema.json"
    ))
    .expect("runtime config schema should parse");
    let template: Value = serde_json::from_str(include_str!(
        "../../templates/vibeguard-config.json.example"
    ))
    .expect("runtime config template should parse");

    let rust_paths = RUNTIME_CONFIG_FIELDS
        .iter()
        .map(|field| field.path.to_string())
        .collect::<BTreeSet<_>>();
    let mut schema_paths = BTreeSet::new();
    schema_leaf_paths(&schema, "", &mut schema_paths);
    let mut template_paths = BTreeSet::new();
    value_leaf_paths(&template, "", &mut template_paths);

    assert_eq!(schema_paths, rust_paths);
    assert_eq!(template_paths, rust_paths);
    for field in RUNTIME_CONFIG_FIELDS {
        let schema_field = schema_at_path(&schema, field.path);
        match field.kind {
            FieldKind::Integer { minimum, maximum } => {
                assert_eq!(schema_field["type"], "integer", "{} type", field.path);
                assert_eq!(schema_field["minimum"], minimum, "{} minimum", field.path);
                assert_eq!(schema_field["maximum"], maximum, "{} maximum", field.path);
            }
            FieldKind::StringEnum { allowed } => {
                let schema_allowed = schema_field["enum"]
                    .as_array()
                    .expect("string enum should be an array")
                    .iter()
                    .map(|value| value.as_str().expect("enum item should be a string"))
                    .collect::<Vec<_>>();
                assert_eq!(schema_allowed, allowed, "{} enum", field.path);
            }
            FieldKind::Version => {
                assert_eq!(schema_field["type"], "integer", "version type");
                assert_eq!(schema_field["const"], 1, "supported version");
            }
        }
    }
    validate_runtime_config_value(Path::new("template"), &template)
        .expect("published template should pass the Rust validator");
}

#[test]
fn runtime_config_semantics_reject_unknown_type_enum_range_and_version() {
    for (value, category) in [
        (json!({"unknown": 1}), "config_unknown_field"),
        (json!({"u16": {"limit": "800"}}), "config_type_error"),
        (json!({"write_mode": "secret-value"}), "config_enum_error"),
        (
            json!({"learn": {"metrics_tail_bytes": 0}}),
            "config_range_error",
        ),
        (json!({"version": 2}), "config_version_error"),
    ] {
        let error = validate_runtime_config_value(Path::new("config.json"), &value)
            .expect_err("invalid config should fail");
        assert!(error.message.contains(category));
        assert!(!error.message.contains("secret-value"));
    }
}

#[test]
fn runtime_config_semantics_accept_empty_partial_and_legacy_clamp_inputs() {
    for value in [
        json!({}),
        json!({"version": 1}),
        json!({"u16": {"limit": 800}}),
        json!({"u16": {"warn_limit": 900, "limit": 800}}),
    ] {
        validate_runtime_config_value(Path::new("config.json"), &value)
            .expect("compatible config should pass");
    }
}
