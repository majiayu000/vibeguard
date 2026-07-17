use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};

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

fn get_int(config: &PathBuf, env_value: Option<&str>) -> Output {
    let mut command = bin();
    command
        .arg("runtime-config-get-int")
        .arg("VG_TEST_LIMIT")
        .arg("u16.limit")
        .arg("800")
        .env("VIBEGUARD_CONFIG_FILE", config);
    match env_value {
        Some(value) => command.env("VG_TEST_LIMIT", value),
        None => command.env_remove("VG_TEST_LIMIT"),
    };
    command.output().expect("runtime config command should run")
}

fn assert_config_failure(output: &Output, category: &str) {
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains(category),
        "expected {category} in stderr: {stderr}"
    );
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
fn runtime_config_get_int_rejects_parse_type_and_range_errors() {
    let dir = runtime_config_temp_dir("int_defaults");
    fs::create_dir_all(&dir).expect("temp dir should be created");
    let config = dir.join("config.json");

    for (body, category) in [
        (
            r#"{"u16":{"limit":"sensitive-value"}}"#,
            "config_type_error",
        ),
        (r#"{"u16":{"limit":true}}"#, "config_type_error"),
        (r#"{"u16":{"limit":-1}}"#, "config_range_error"),
        (r#"{"u16":{"limit":12.5}}"#, "config_type_error"),
        (r#"{"u16":{"limit":"#, "config_json_error"),
    ] {
        fs::write(&config, body).expect("runtime config should be written");
        let output = get_int(&config, None);
        assert_config_failure(&output, category);
        assert!(!String::from_utf8_lossy(&output.stderr).contains("sensitive-value"));
    }

    fs::write(&config, r#"{"u16":{"limit":1000001}}"#).expect("runtime config should be written");
    assert_config_failure(&get_int(&config, None), "config_range_error");

    fs::write(&config, r#"{"u16":{"limit":"sensitive-value"}}"#)
        .expect("runtime config should be written");
    let masked = get_int(&config, Some("999"));
    assert_config_failure(&masked, "config_type_error");
    assert!(!String::from_utf8_lossy(&masked.stderr).contains("sensitive-value"));
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn runtime_config_get_int_resolves_w14_cooldown_contract() {
    let dir = runtime_config_temp_dir("w14_cooldown");
    fs::create_dir_all(&dir).expect("temp dir should be created");
    let config = dir.join("config.json");
    fs::write(&config, r#"{"w14":{"cooldown_seconds":1800}}"#)
        .expect("runtime config should be written");

    let resolve = |env_value: Option<&str>| {
        let mut command = bin();
        command
            .arg("runtime-config-get-int")
            .arg("VIBEGUARD_W14_COOLDOWN_SECONDS")
            .arg("w14.cooldown_seconds")
            .arg("3600")
            .env("VIBEGUARD_CONFIG_FILE", &config);
        match env_value {
            Some(value) => command.env("VIBEGUARD_W14_COOLDOWN_SECONDS", value),
            None => command.env_remove("VIBEGUARD_W14_COOLDOWN_SECONDS"),
        };
        let output = command.output().expect("runtime config command should run");
        assert_eq!(output.status.code(), Some(0));
        String::from_utf8(output.stdout).expect("runtime config output should be UTF-8")
    };

    assert_eq!(resolve(None).trim(), "1800");
    assert_eq!(resolve(Some("7200")).trim(), "7200");
    assert_eq!(resolve(Some("0")).trim(), "0");
    assert_eq!(resolve(Some("not-a-number")).trim(), "1800");

    fs::write(&config, r#"{"w14":{}}"#).expect("runtime config should be rewritten");
    assert_eq!(resolve(None).trim(), "3600");

    for (body, category) in [
        (
            r#"{"w14":{"cooldown_seconds":"3600"}}"#,
            "config_type_error",
        ),
        (r#"{"w14":{"cooldown_seconds":-1}}"#, "config_range_error"),
    ] {
        fs::write(&config, body).expect("runtime config should be rewritten");
        let output = bin()
            .arg("runtime-config-get-int")
            .arg("VIBEGUARD_W14_COOLDOWN_SECONDS")
            .arg("w14.cooldown_seconds")
            .arg("3600")
            .env("VIBEGUARD_CONFIG_FILE", &config)
            .env_remove("VIBEGUARD_W14_COOLDOWN_SECONDS")
            .output()
            .expect("runtime config command should run");
        assert_config_failure(&output, category);
    }

    fs::remove_dir_all(dir).expect("temp dir should be removed");
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
fn runtime_config_get_str_rejects_parse_type_enum_and_empty_errors() {
    let dir = runtime_config_temp_dir("str_defaults");
    fs::create_dir_all(&dir).expect("temp dir should be created");
    let config = dir.join("config.json");

    for (body, category) in [
        (r#"{"write_mode":""}"#, "config_enum_error"),
        (r#"{"write_mode":true}"#, "config_type_error"),
        (r#"{"write_mode":12}"#, "config_type_error"),
        (r#"{"write_mode":"#, "config_json_error"),
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
        assert_config_failure(&output, category);
    }
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn runtime_config_validate_classifies_missing_valid_and_invalid_content() {
    let dir = runtime_config_temp_dir("validate_content");
    fs::create_dir_all(&dir).expect("temp dir should be created");
    let config = dir.join("config.json");

    let missing = bin()
        .arg("runtime-config-validate")
        .arg(&config)
        .output()
        .expect("runtime config validator should run");
    assert_eq!(missing.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&missing.stdout).trim(), "MISSING");

    fs::write(&config, r#"{"version":1,"write_mode":"block"}"#)
        .expect("runtime config should be written");
    let valid = bin()
        .arg("runtime-config-validate")
        .arg(&config)
        .output()
        .expect("runtime config validator should run");
    assert_eq!(valid.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&valid.stdout).trim(), "VALID");

    fs::write(&config, [0xff, 0xfe]).expect("invalid UTF-8 should be written");
    let utf8 = bin()
        .arg("runtime-config-validate")
        .arg(&config)
        .output()
        .expect("runtime config validator should run");
    assert_config_failure(&utf8, "config_utf8_error");

    fs::write(&config, r#"{"write_mode":"sensitive-secret"}"#)
        .expect("invalid enum should be written");
    let invalid_enum = bin()
        .arg("runtime-config-validate")
        .arg(&config)
        .output()
        .expect("runtime config validator should run");
    assert_config_failure(&invalid_enum, "config_enum_error");
    assert!(!String::from_utf8_lossy(&invalid_enum.stderr).contains("sensitive-secret"));

    let _ = fs::remove_dir_all(dir);
}

#[test]
fn runtime_config_validate_rejects_directory_without_opening_it() {
    let dir = runtime_config_temp_dir("directory");
    fs::create_dir_all(&dir).expect("temp dir should be created");
    let output = bin()
        .arg("runtime-config-validate")
        .arg(&dir)
        .output()
        .expect("runtime config validator should run");
    assert_config_failure(&output, "config_path_type_error");
    let _ = fs::remove_dir_all(dir);
}

#[cfg(unix)]
#[test]
fn runtime_config_validate_handles_symlink_fifo_and_unreadable_states() {
    use std::os::unix::fs::{PermissionsExt, symlink};

    let dir = runtime_config_temp_dir("path_states");
    fs::create_dir_all(&dir).expect("temp dir should be created");
    let target = dir.join("target.json");
    let readable_link = dir.join("readable-link.json");
    fs::write(&target, r#"{"write_mode":"warn"}"#).expect("target should be written");
    symlink(&target, &readable_link).expect("readable symlink should be created");
    let readable = bin()
        .arg("runtime-config-validate")
        .arg(&readable_link)
        .output()
        .expect("runtime config validator should run");
    assert_eq!(readable.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&readable.stdout).trim(), "VALID");

    let dangling_link = dir.join("dangling-link.json");
    symlink(dir.join("missing-target.json"), &dangling_link)
        .expect("dangling symlink should be created");
    let dangling = bin()
        .arg("runtime-config-validate")
        .arg(&dangling_link)
        .output()
        .expect("runtime config validator should run");
    assert_config_failure(&dangling, "config_path_target_error");

    let fifo = dir.join("config.fifo");
    let mkfifo = Command::new("mkfifo")
        .arg(&fifo)
        .status()
        .expect("mkfifo should run");
    assert!(mkfifo.success());
    let fifo_output = bin()
        .arg("runtime-config-validate")
        .arg(&fifo)
        .output()
        .expect("runtime config validator should not block on FIFO");
    assert_config_failure(&fifo_output, "config_path_type_error");

    fs::set_permissions(&target, fs::Permissions::from_mode(0o000))
        .expect("target permissions should be removed");
    let unreadable = bin()
        .arg("runtime-config-validate")
        .arg(&target)
        .output()
        .expect("runtime config validator should run");
    fs::set_permissions(&target, fs::Permissions::from_mode(0o600))
        .expect("target permissions should be restored");
    assert_config_failure(&unreadable, "config_read_error");

    let _ = fs::remove_dir_all(dir);
}
