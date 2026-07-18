use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"))
}

fn runtime_config_fixture_dir(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "vibeguard-runtime-policy-config-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

fn write_policy(repo: &Path, body: &str) {
    fs::create_dir_all(repo).expect("repo temp dir should be created");
    fs::write(repo.join(".vibeguard.json"), body).expect("project policy should be written");
}

fn run_runtime_policy_with_user_config(repo: &Path, user_config: &Path) -> std::process::Output {
    bin()
        .arg("runtime-policy-check")
        .arg("--cwd")
        .arg(repo)
        .arg("pre-bash-guard.sh")
        .current_dir(repo)
        .env_remove("VIBEGUARD_PROJECT_CONFIG")
        .env("VIBEGUARD_USER_CONFIG_FILE", user_config)
        .output()
        .expect("runtime policy command should run")
}

fn policy_json(output: &std::process::Output) -> serde_json::Value {
    serde_json::from_slice(&output.stdout).unwrap_or_else(|err| {
        panic!(
            "runtime-policy-check stdout should be JSON: {err}; stdout={}; stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    })
}

#[test]
fn runtime_policy_check_validates_user_runtime_config_before_policy() {
    let repo = runtime_config_fixture_dir("bad_user_config");
    write_policy(&repo, r#"{}"#);
    let user_config = repo.join("bad-config.json");
    fs::write(&user_config, r#"{"write_mode":"#).expect("runtime config should be written");

    let output = bin()
        .arg("runtime-policy-check")
        .arg("--cwd")
        .arg(&repo)
        .arg("pre-bash-guard.sh")
        .current_dir(&repo)
        .env_remove("VIBEGUARD_PROJECT_CONFIG")
        .env("VIBEGUARD_USER_CONFIG_FILE", &user_config)
        .output()
        .expect("runtime policy command should run");

    assert_eq!(output.status.code(), Some(30));
    let value = policy_json(&output);
    assert_eq!(value["decision"], "error");
    assert!(
        value["reason"]
            .as_str()
            .unwrap_or("")
            .contains("category=config_json_error")
    );
    assert!(String::from_utf8_lossy(&output.stderr).contains("category=config_json_error"));
    let _ = fs::remove_dir_all(repo);
}

#[test]
fn runtime_policy_check_shares_semantic_and_path_decisions_without_value_leaks() {
    let repo = runtime_config_fixture_dir("runtime_config_decisions");
    write_policy(&repo, r#"{}"#);
    let user_config = repo.join("user-config.json");

    fs::write(&user_config, r#"{"write_mode":"sensitive-policy-value"}"#)
        .expect("runtime config should be written");
    let semantic = run_runtime_policy_with_user_config(&repo, &user_config);
    assert_eq!(semantic.status.code(), Some(30));
    let semantic_value = policy_json(&semantic);
    assert!(
        semantic_value["reason"]
            .as_str()
            .unwrap_or("")
            .contains("category=config_enum_error")
    );
    assert!(!String::from_utf8_lossy(&semantic.stderr).contains("sensitive-policy-value"));

    fs::remove_file(&user_config).expect("runtime config should be removed");
    fs::create_dir(&user_config).expect("runtime config directory should be created");
    let path_type = run_runtime_policy_with_user_config(&repo, &user_config);
    assert_eq!(path_type.status.code(), Some(20));
    let path_value = policy_json(&path_type);
    assert!(
        path_value["reason"]
            .as_str()
            .unwrap_or("")
            .contains("category=config_path_type_error")
    );

    let _ = fs::remove_dir_all(repo);
}
