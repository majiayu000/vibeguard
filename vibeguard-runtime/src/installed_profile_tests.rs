use super::*;
use serde_json::{Value, json};
use std::time::{SystemTime, UNIX_EPOCH};

fn temp_install_profile_home(name: &str) -> PathBuf {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let home = std::env::temp_dir().join(format!(
        "vibeguard_installed_profile_{name}_{}_{}",
        std::process::id(),
        unique
    ));
    fs::create_dir_all(home.join(".vibeguard")).expect("state directory should be created");
    home
}

fn state(profile: Value, generation: u64, complete: bool) -> Value {
    json!({
        "version": 1,
        "generation": generation,
        "complete": complete,
        "profile": profile,
        "files": {}
    })
}

fn write_state(home: &Path, name: &str, value: &Value) {
    fs::write(
        home.join(".vibeguard").join(name),
        serde_json::to_string(value).expect("state should serialize"),
    )
    .expect("state should be written");
}

#[test]
fn missing_install_state_has_no_installed_profile() {
    let home = temp_install_profile_home("missing");
    assert_eq!(installed_profile(&home), Ok(None));
    fs::remove_dir_all(home).expect("temp home should be removed");
}

#[test]
fn reads_supported_installed_profiles() {
    for profile in ["minimal", "full"] {
        let home = temp_install_profile_home(profile);
        write_state(&home, "install-state.json", &state(json!(profile), 2, true));
        assert_eq!(installed_profile(&home), Ok(Some(profile.to_string())));
        fs::remove_dir_all(home).expect("temp home should be removed");
    }
}

#[test]
fn rejects_previous_only_state() {
    let home = temp_install_profile_home("previous_only");
    write_state(
        &home,
        "install-state.previous.json",
        &state(json!("core"), 1, true),
    );
    let error = installed_profile(&home).expect_err("previous-only state should fail");
    assert!(error.contains("current install-state is missing"));
    fs::remove_dir_all(home).expect("temp home should be removed");
}

#[test]
fn incomplete_upgrade_uses_previous_complete_profile() {
    let home = temp_install_profile_home("incomplete_upgrade");
    write_state(&home, "install-state.json", &state(json!("full"), 2, false));
    write_state(
        &home,
        "install-state.previous.json",
        &state(json!("core"), 1, true),
    );
    assert_eq!(installed_profile(&home), Ok(Some("core".to_string())));
    fs::remove_dir_all(home).expect("temp home should be removed");
}

#[test]
fn incomplete_first_install_uses_default_profile() {
    let home = temp_install_profile_home("incomplete_first_install");
    write_state(
        &home,
        "install-state.json",
        &state(json!("strict"), 1, false),
    );
    assert_eq!(installed_profile(&home), Ok(None));
    fs::remove_dir_all(home).expect("temp home should be removed");
}

#[test]
fn rejects_incomplete_state_with_invalid_generation_relationship() {
    for (name, current_generation, previous_generation, expected) in [
        ("first_generation_two", 2, None, "must use generation 1"),
        (
            "skipped_generation",
            4,
            Some(2),
            "exactly one generation newer",
        ),
        (
            "repeated_generation",
            2,
            Some(2),
            "exactly one generation newer",
        ),
    ] {
        let home = temp_install_profile_home(name);
        write_state(
            &home,
            "install-state.json",
            &state(json!("full"), current_generation, false),
        );
        if let Some(previous_generation) = previous_generation {
            write_state(
                &home,
                "install-state.previous.json",
                &state(json!("core"), previous_generation, true),
            );
        }
        let error = installed_profile(&home).expect_err("invalid generation should fail");
        assert!(error.contains(expected), "unexpected error: {error}");
        fs::remove_dir_all(home).expect("temp home should be removed");
    }
}

#[test]
fn rejects_malformed_and_unsupported_profiles() {
    for (name, profile, expected) in [
        ("wrong_type", json!(7), "profile must be a string"),
        (
            "unsupported",
            json!("turbo"),
            "unsupported install-state profile",
        ),
    ] {
        let home = temp_install_profile_home(name);
        write_state(&home, "install-state.json", &state(profile, 1, true));
        let error = installed_profile(&home).expect_err("invalid profile should fail");
        assert!(error.contains(expected), "unexpected error: {error}");
        fs::remove_dir_all(home).expect("temp home should be removed");
    }
}

#[test]
fn rejects_invalid_json_and_generation_regression() {
    let invalid_home = temp_install_profile_home("invalid_json");
    fs::write(invalid_home.join(".vibeguard/install-state.json"), "{")
        .expect("invalid state fixture should be written");
    let error = installed_profile(&invalid_home).expect_err("invalid JSON should fail");
    assert!(error.contains("invalid install-state"));
    fs::remove_dir_all(invalid_home).expect("temp home should be removed");

    let regressed_home = temp_install_profile_home("generation_regression");
    write_state(
        &regressed_home,
        "install-state.json",
        &state(json!("full"), 1, true),
    );
    write_state(
        &regressed_home,
        "install-state.previous.json",
        &state(json!("core"), 2, true),
    );
    let error = installed_profile(&regressed_home)
        .expect_err("current generation older than previous should fail");
    assert!(error.contains("older than previous snapshot"));
    fs::remove_dir_all(regressed_home).expect("temp home should be removed");
}
