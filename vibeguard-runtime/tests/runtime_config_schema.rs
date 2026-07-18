use serde_json::Value;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"))
}

fn published_schema() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../schemas/vibeguard-runtime-config.schema.json");
    let bytes = fs::read(path).expect("published runtime config schema should be readable");
    serde_json::from_slice(&bytes).expect("published runtime config schema should be JSON")
}

fn schema_fixture_path(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "vibeguard-runtime-config-schema-{label}-{}-{}.json",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

#[test]
fn published_schema_is_valid_draft_2020_12() {
    let schema = published_schema();
    jsonschema::draft202012::meta::validate(&schema)
        .expect("published runtime config schema should pass Draft 2020-12 meta-validation");
}

#[test]
fn schema_runtime_validator_and_getter_accept_integral_number_representations() {
    let schema = published_schema();
    let validator = jsonschema::draft202012::new(&schema)
        .expect("published runtime config schema should compile");

    for (label, body) in [
        ("decimal", r#"{"version":1.0,"u16":{"limit":1.0}}"#),
        ("exponent", r#"{"version":1e0,"u16":{"limit":1e0}}"#),
    ] {
        let instance: Value = serde_json::from_str(body).expect("fixture should be valid JSON");
        assert!(validator.is_valid(&instance), "schema rejected {label}");

        let path = schema_fixture_path(label);
        fs::write(&path, body).expect("runtime config fixture should be written");
        let validation = bin()
            .arg("runtime-config-validate")
            .arg(&path)
            .output()
            .expect("runtime config validator should run");
        assert!(validation.status.success(), "{label}: {validation:?}");

        let getter = bin()
            .args([
                "runtime-config-get-int",
                "VG_SCHEMA_TEST_UNSET",
                "u16.limit",
                "9",
            ])
            .env_remove("VG_SCHEMA_TEST_UNSET")
            .env("_VG_CONFIG_FILE", &path)
            .output()
            .expect("runtime config getter should run");
        assert!(getter.status.success(), "{label}: {getter:?}");
        assert_eq!(getter.stdout, b"1\n", "{label}");
        assert!(getter.stderr.is_empty(), "{label}: {getter:?}");
        let _ = fs::remove_file(path);
    }
}

#[test]
fn schema_and_runtime_reject_non_integral_numbers() {
    let schema = published_schema();
    let validator = jsonschema::draft202012::new(&schema)
        .expect("published runtime config schema should compile");
    let body = r#"{"u16":{"limit":1.5}}"#;
    let instance: Value = serde_json::from_str(body).expect("fixture should be valid JSON");
    assert!(!validator.is_valid(&instance));

    let path = schema_fixture_path("non-integral");
    fs::write(&path, body).expect("runtime config fixture should be written");
    let output = bin()
        .arg("runtime-config-validate")
        .arg(&path)
        .output()
        .expect("runtime config validator should run");
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("category=config_type_error"));
    let _ = fs::remove_file(path);
}
