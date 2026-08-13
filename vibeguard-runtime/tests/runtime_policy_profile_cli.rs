mod common;

use common::{bin, unique_temp_dir};
use std::fs;
use std::path::Path;

fn write_policy(repo: &Path, body: &str) {
    fs::create_dir_all(repo).expect("repo temp dir should be created");
    fs::write(repo.join(".vibeguard.json"), body).expect("project policy should be written");
}

fn run_runtime_policy_with_profile(
    repo: &Path,
    hook_name: &str,
    profile: &str,
) -> std::process::Output {
    bin()
        .arg("runtime-policy-check")
        .arg("--cwd")
        .arg(repo)
        .arg(hook_name)
        .current_dir(repo)
        .env_remove("VIBEGUARD_PROJECT_CONFIG")
        .env_remove("VIBEGUARD_USER_CONFIG_FILE")
        .env("VIBEGUARD_PROFILE", profile)
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
fn runtime_policy_check_uses_env_profile_when_project_config_is_absent() {
    for profile in ["minimal", "core", "full", "strict"] {
        let repo = unique_temp_dir(&format!("env_profile_{profile}"));
        fs::create_dir_all(&repo).expect("repo temp dir should be created");

        let output = run_runtime_policy_with_profile(&repo, "stop-guard.sh", profile);
        let value = policy_json(&output);

        assert_eq!(value["profile"], profile);
        if matches!(profile, "full" | "strict") {
            assert_eq!(output.status.code(), Some(0), "{profile}: {value}");
            assert_eq!(value["decision"], "run");
            assert!(value["reason"].is_null());
        } else {
            assert_eq!(output.status.code(), Some(10), "{profile}: {value}");
            assert_eq!(value["decision"], "skip");
            assert!(
                value["reason"]
                    .as_str()
                    .unwrap_or("")
                    .contains(&format!("profile={profile} excludes stop-guard")),
                "{value}"
            );
        }
        assert_eq!(String::from_utf8_lossy(&output.stderr), "");
        let _ = fs::remove_dir_all(repo);
    }
}

#[test]
fn runtime_policy_check_project_profile_overrides_env_profile() {
    for profile in ["minimal", "core", "full", "strict"] {
        let repo = unique_temp_dir(&format!("project_profile_{profile}"));
        write_policy(&repo, &format!(r#"{{"profile":"{profile}"}}"#));

        let output = run_runtime_policy_with_profile(&repo, "stop-guard.sh", "core");
        let value = policy_json(&output);

        assert_eq!(value["profile"], profile);
        if matches!(profile, "full" | "strict") {
            assert_eq!(output.status.code(), Some(0), "{profile}: {value}");
            assert_eq!(value["decision"], "run");
        } else {
            assert_eq!(output.status.code(), Some(10), "{profile}: {value}");
            assert_eq!(value["decision"], "skip");
        }
        assert_eq!(String::from_utf8_lossy(&output.stderr), "");
        let _ = fs::remove_dir_all(repo);
    }
}

#[test]
fn runtime_policy_check_project_profile_ignores_invalid_env_profile() {
    let repo = unique_temp_dir("project_profile_invalid_env");
    write_policy(&repo, r#"{"profile":"full"}"#);

    let output = run_runtime_policy_with_profile(&repo, "stop-guard.sh", "invalid");
    let value = policy_json(&output);

    assert_eq!(output.status.code(), Some(0), "{value}");
    assert_eq!(value["decision"], "run");
    assert_eq!(value["profile"], "full");
    assert!(value["reason"].is_null());
    assert_eq!(String::from_utf8_lossy(&output.stderr), "");
    let _ = fs::remove_dir_all(repo);
}
