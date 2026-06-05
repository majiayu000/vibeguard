use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"))
}

fn runtime_config_temp_dir(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "vibeguard-runtime-config-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

#[test]
fn runtime_config_get_int_preserves_env_json_default_order() {
    let dir = runtime_config_temp_dir("int");
    fs::create_dir_all(&dir).expect("temp dir should be created");
    let config = dir.join("config.json");
    fs::write(&config, r#"{"u16":{"limit":1234}}"#).expect("runtime config should be written");

    let json = bin()
        .arg("runtime-config-get-int")
        .arg("VG_TEST_LIMIT")
        .arg("u16.limit")
        .arg("800")
        .env("VIBEGUARD_CONFIG_FILE", &config)
        .env_remove("VG_TEST_LIMIT")
        .output()
        .expect("runtime config command should run");
    assert_eq!(json.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&json.stdout).trim(), "1234");

    let env_override = bin()
        .arg("runtime-config-get-int")
        .arg("VG_TEST_LIMIT")
        .arg("u16.limit")
        .arg("800")
        .env("VIBEGUARD_CONFIG_FILE", &config)
        .env("VG_TEST_LIMIT", "999")
        .output()
        .expect("runtime config command should run");
    assert_eq!(String::from_utf8_lossy(&env_override.stdout).trim(), "999");

    let bad_env = bin()
        .arg("runtime-config-get-int")
        .arg("VG_TEST_LIMIT")
        .arg("u16.limit")
        .arg("800")
        .env("VIBEGUARD_CONFIG_FILE", &config)
        .env("VG_TEST_LIMIT", "not-a-number")
        .output()
        .expect("runtime config command should run");
    assert_eq!(String::from_utf8_lossy(&bad_env.stdout).trim(), "1234");

    let missing = bin()
        .arg("runtime-config-get-int")
        .arg("VG_TEST_LIMIT")
        .arg("u16.missing")
        .arg("800")
        .env("VIBEGUARD_CONFIG_FILE", &config)
        .env_remove("VG_TEST_LIMIT")
        .output()
        .expect("runtime config command should run");
    assert_eq!(String::from_utf8_lossy(&missing.stdout).trim(), "800");
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn runtime_config_get_int_defaults_for_parse_errors_and_wrong_types() {
    let dir = runtime_config_temp_dir("int_defaults");
    fs::create_dir_all(&dir).expect("temp dir should be created");
    let config = dir.join("config.json");

    for body in [
        r#"{"u16":{"limit":"oops"}}"#,
        r#"{"u16":{"limit":true}}"#,
        r#"{"u16":{"limit":-1}}"#,
        r#"{"u16":{"limit":12.5}}"#,
        r#"{"u16":{"limit":"#,
    ] {
        fs::write(&config, body).expect("runtime config should be written");
        let output = bin()
            .arg("runtime-config-get-int")
            .arg("VG_TEST_LIMIT")
            .arg("u16.limit")
            .arg("800")
            .env("VIBEGUARD_CONFIG_FILE", &config)
            .env_remove("VG_TEST_LIMIT")
            .output()
            .expect("runtime config command should run");
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "800");
    }

    fs::write(&config, r#"{"u16":{"limit":9223372036854775808}}"#)
        .expect("runtime config should be written");
    let output = bin()
        .arg("runtime-config-get-int")
        .arg("VG_TEST_LIMIT")
        .arg("u16.limit")
        .arg("800")
        .env("VIBEGUARD_CONFIG_FILE", &config)
        .env_remove("VG_TEST_LIMIT")
        .output()
        .expect("runtime config command should run");
    assert_eq!(output.status.code(), Some(0));
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "9223372036854775808"
    );
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn runtime_config_get_str_preserves_env_json_default_order() {
    let dir = runtime_config_temp_dir("str");
    fs::create_dir_all(&dir).expect("temp dir should be created");
    let config = dir.join("config.json");
    fs::write(&config, r#"{"write_mode":"block"}"#).expect("runtime config should be written");

    let json = bin()
        .arg("runtime-config-get-str")
        .arg("VG_TEST_MODE")
        .arg("write_mode")
        .arg("warn")
        .env("VIBEGUARD_CONFIG_FILE", &config)
        .env_remove("VG_TEST_MODE")
        .output()
        .expect("runtime config command should run");
    assert_eq!(json.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&json.stdout).trim(), "block");

    let env_override = bin()
        .arg("runtime-config-get-str")
        .arg("VG_TEST_MODE")
        .arg("write_mode")
        .arg("warn")
        .env("VIBEGUARD_CONFIG_FILE", &config)
        .env("VG_TEST_MODE", "warn")
        .output()
        .expect("runtime config command should run");
    assert_eq!(String::from_utf8_lossy(&env_override.stdout).trim(), "warn");

    let missing = bin()
        .arg("runtime-config-get-str")
        .arg("VG_TEST_MODE")
        .arg("missing")
        .arg("warn")
        .env("VIBEGUARD_CONFIG_FILE", &config)
        .env_remove("VG_TEST_MODE")
        .output()
        .expect("runtime config command should run");
    assert_eq!(String::from_utf8_lossy(&missing.stdout).trim(), "warn");
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn runtime_config_get_str_defaults_for_parse_errors_wrong_types_and_empty_strings() {
    let dir = runtime_config_temp_dir("str_defaults");
    fs::create_dir_all(&dir).expect("temp dir should be created");
    let config = dir.join("config.json");

    for body in [
        r#"{"write_mode":""}"#,
        r#"{"write_mode":true}"#,
        r#"{"write_mode":12}"#,
        r#"{"write_mode":"#,
    ] {
        fs::write(&config, body).expect("runtime config should be written");
        let output = bin()
            .arg("runtime-config-get-str")
            .arg("VG_TEST_MODE")
            .arg("write_mode")
            .arg("warn")
            .env("VIBEGUARD_CONFIG_FILE", &config)
            .env_remove("VG_TEST_MODE")
            .output()
            .expect("runtime config command should run");
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "warn");
    }
    let _ = fs::remove_dir_all(dir);
}
