mod common;

use common::{bin, unique_temp_dir};
use std::fs;

#[test]
fn project_config_validate_reports_accumulated_errors_and_hints() {
    let dir = unique_temp_dir("project_config_invalid");
    fs::create_dir_all(&dir).expect("temp dir should be created");
    let config = dir.join(".vibeguard.json");
    fs::write(
        &config,
        r#"{
          "profile": "strictest",
          "write_mode": "block",
          "gc": {
            "log_threshold_mb": 0,
            "unexpected_gc_key": 1
          }
        }"#,
    )
    .expect("project config should be written");

    let output = bin()
        .arg("project-config-validate")
        .arg(&config)
        .output()
        .expect("project config validate should run");

    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains(".profile: unsupported value strictest"));
    assert!(stderr.contains(".write_mode: unknown property"));
    assert!(stderr.contains("write_mode belongs in ~/.vibeguard/config.json"));
    assert!(stderr.contains(".gc.log_threshold_mb: expected integer >= 1"));
    assert!(stderr.contains(".gc.unexpected_gc_key: unknown property"));
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn project_config_value_reads_valid_values_and_defaults_missing_values() {
    let dir = unique_temp_dir("project_config_value");
    fs::create_dir_all(&dir).expect("temp dir should be created");
    let config = dir.join(".vibeguard.json");
    fs::write(&config, r#"{"profile":"full","gc":{"log_threshold_mb":7}}"#)
        .expect("project config should be written");

    let value = bin()
        .arg("project-config-value")
        .arg(&config)
        .arg("gc.log_threshold_mb")
        .arg("10")
        .output()
        .expect("project config value should run");
    assert_eq!(value.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&value.stdout).trim(), "7");

    let missing = bin()
        .arg("project-config-value")
        .arg(&config)
        .arg("gc.missing")
        .arg("10")
        .output()
        .expect("project config value should run");
    assert_eq!(missing.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&missing.stdout).trim(), "10");
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn project_config_validate_accepts_schema_backed_values() {
    let dir = unique_temp_dir("project_config_schema_values");
    fs::create_dir_all(&dir).expect("temp dir should be created");
    let config = dir.join(".vibeguard.json");
    fs::write(
        &config,
        r#"{
          "languages": ["javascript"],
          "disabled_guards": ["check_dependency_changes"],
          "gc": {
            "catchup_interval_hours": 24
          }
        }"#,
    )
    .expect("project config should be written");

    let output = bin()
        .arg("project-config-validate")
        .arg(&config)
        .output()
        .expect("project config validate should run");

    assert_eq!(output.status.code(), Some(0));
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn project_config_value_fails_visibly_before_reading_invalid_config() {
    let dir = unique_temp_dir("project_config_invalid_value");
    fs::create_dir_all(&dir).expect("temp dir should be created");
    let config = dir.join(".vibeguard.json");
    fs::write(&config, r#"{"gc":{"log_threshold_mb":0}}"#)
        .expect("project config should be written");

    let output = bin()
        .arg("project-config-value")
        .arg(&config)
        .arg("gc.log_threshold_mb")
        .arg("10")
        .output()
        .expect("project config value should run");

    assert_eq!(output.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains(".gc.log_threshold_mb: expected integer >= 1")
    );
    let _ = fs::remove_dir_all(dir);
}
