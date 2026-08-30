use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};

use serde_json::{Value, json};

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"))
}

fn guided_config_command(home: &PathBuf, cwd: &PathBuf, args: &[&str]) -> Command {
    let mut command = bin();
    command
        .args(args)
        .current_dir(cwd)
        .env("HOME", home)
        .env_remove("VIBEGUARD_CONFIG_FILE")
        .env_remove("VG_INTERNAL_CONFIG_FILE")
        .env_remove("_VG_CONFIG_FILE")
        .env_remove("VIBEGUARD_PROJECT_CONFIG")
        .env_remove("VG_INTERNAL_POLICY_CWD")
        .env_remove("VIBEGUARD_POLICY_CWD")
        .env_remove("VIBEGUARD_PROJECT_ROOT")
        .env_remove("VIBEGUARD_PROJECT_CWD")
        .env_remove("VIBEGUARD_CHURN_INFORMATIONAL_EDIT_COUNT")
        .env_remove("VIBEGUARD_CHURN_WARNING_EDIT_COUNT")
        .env_remove("VIBEGUARD_CHURN_CRITICAL_EDIT_COUNT")
        .env_remove("VIBEGUARD_CHURN_CRITICAL_BUILD_FAILURE_COUNT");
    command
}

fn json_at_path<'a>(value: &'a Value, path: &str) -> &'a Value {
    path.split('.').fold(value, |node, key| &node[key])
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
fn guided_config_commands_init_show_set_reset_and_preserve_layers() {
    let root = runtime_config_temp_dir("guided_commands");
    let home = root.join("home");
    let repo = root.join("repo");
    fs::create_dir_all(&home).expect("home should be created");
    fs::create_dir_all(&repo).expect("repo should be created");
    assert!(
        Command::new("git")
            .args(["init", "-q"])
            .current_dir(&repo)
            .status()
            .expect("git init should run")
            .success()
    );

    let repo_text = repo.to_string_lossy().into_owned();
    let user_path = home.join(".vibeguard/config.json");
    let init_user = guided_config_command(
        &home,
        &repo,
        &["config", "init", "--scope", "user", "--cwd", &repo_text],
    )
    .output()
    .expect("user config init should run");
    assert!(init_user.status.success(), "{init_user:?}");
    assert!(String::from_utf8_lossy(&init_user.stdout).contains(&user_path.display().to_string()));
    assert_eq!(
        serde_json::from_slice::<Value>(&fs::read(&user_path).expect("user config should exist"))
            .expect("initialized user config should be JSON"),
        json!({"version": 1})
    );

    let before_existing_init = fs::read(&user_path).expect("user config should be readable");
    let existing_init = guided_config_command(
        &home,
        &repo,
        &["config", "init", "--scope", "user", "--cwd", &repo_text],
    )
    .output()
    .expect("second user config init should run");
    assert_eq!(existing_init.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&existing_init.stderr).contains("already exists"));
    assert!(
        String::from_utf8_lossy(&existing_init.stderr).contains(&user_path.display().to_string())
    );
    assert_eq!(
        fs::read(&user_path).expect("user config should remain"),
        before_existing_init
    );

    let show = guided_config_command(
        &home,
        &repo,
        &["config", "show", "--cwd", &repo_text, "--json"],
    )
    .output()
    .expect("config show should run");
    assert!(show.status.success(), "{show:?}");
    let entries = serde_json::from_slice::<Vec<Value>>(&show.stdout)
        .expect("config show JSON should be an array");
    let u16_limit = entries
        .iter()
        .find(|entry| entry["key"] == "u16.limit")
        .expect("config show should include u16.limit");
    assert_eq!(u16_limit["value"], 800);
    assert_eq!(u16_limit["source"], "default");
    assert!(
        u16_limit["category"]
            .as_str()
            .is_some_and(|value| !value.is_empty())
    );
    assert!(
        u16_limit["description"]
            .as_str()
            .is_some_and(|value| !value.is_empty())
    );

    let set_user = guided_config_command(
        &home,
        &repo,
        &[
            "config",
            "set",
            "u16.limit",
            "1234",
            "--scope",
            "user",
            "--cwd",
            &repo_text,
        ],
    )
    .output()
    .expect("user config set should run");
    assert!(set_user.status.success(), "{set_user:?}");
    assert!(String::from_utf8_lossy(&set_user.stdout).contains("u16.limit"));
    assert!(String::from_utf8_lossy(&set_user.stdout).contains(&user_path.display().to_string()));
    let user_value = serde_json::from_slice::<Value>(&fs::read(&user_path).unwrap())
        .expect("user config should remain JSON");
    assert_eq!(json_at_path(&user_value, "u16.limit"), &json!(1234));
    assert_eq!(user_value["version"], 1);

    let set_skills = guided_config_command(
        &home,
        &repo,
        &[
            "config",
            "set",
            "disabled_skills",
            "plan-flow,fixflow",
            "--scope",
            "user",
            "--cwd",
            &repo_text,
        ],
    )
    .output()
    .expect("string-array config set should run");
    assert!(set_skills.status.success(), "{set_skills:?}");
    let user_value = serde_json::from_slice::<Value>(&fs::read(&user_path).unwrap())
        .expect("user config should remain JSON");
    assert_eq!(
        user_value["disabled_skills"],
        json!(["plan-flow", "fixflow"])
    );

    let reset_skills = guided_config_command(
        &home,
        &repo,
        &[
            "config",
            "set",
            "disabled_skills",
            "",
            "--scope",
            "user",
            "--cwd",
            &repo_text,
        ],
    )
    .output()
    .expect("empty string-array config set should run");
    assert!(reset_skills.status.success(), "{reset_skills:?}");
    let user_value = serde_json::from_slice::<Value>(&fs::read(&user_path).unwrap())
        .expect("user config should remain JSON");
    assert_eq!(user_value["disabled_skills"], json!([]));

    let reset_user = guided_config_command(
        &home,
        &repo,
        &[
            "config",
            "reset",
            "u16.limit",
            "--scope",
            "user",
            "--cwd",
            &repo_text,
        ],
    )
    .output()
    .expect("user config reset should run");
    assert!(reset_user.status.success(), "{reset_user:?}");
    assert!(String::from_utf8_lossy(&reset_user.stdout).contains("u16.limit"));
    let user_value = serde_json::from_slice::<Value>(&fs::read(&user_path).unwrap())
        .expect("user config should remain JSON");
    assert!(user_value["u16"].get("limit").is_none());
    assert_eq!(user_value["version"], 1);

    let project_path = repo.join(".vibeguard.json");
    let init_project = guided_config_command(
        &home,
        &repo,
        &["config", "init", "--scope", "project", "--cwd", &repo_text],
    )
    .output()
    .expect("project config init should run");
    assert!(init_project.status.success(), "{init_project:?}");
    assert!(
        String::from_utf8_lossy(&init_project.stdout).contains(&project_path.display().to_string())
    );

    for (key, value) in [
        ("profile", "strict"),
        ("enforcement", "warn"),
        ("languages", "rust,typescript"),
        ("u16.limit", "1200"),
    ] {
        let output = guided_config_command(
            &home,
            &repo,
            &[
                "config", "set", key, value, "--scope", "project", "--cwd", &repo_text,
            ],
        )
        .output()
        .expect("project config set should run");
        assert!(output.status.success(), "{key}: {output:?}");
    }
    let project_value = serde_json::from_slice::<Value>(&fs::read(&project_path).unwrap())
        .expect("project config should remain JSON");
    assert_eq!(project_value["profile"], "strict");
    assert_eq!(project_value["enforcement"], "warn");
    assert_eq!(project_value["languages"], json!(["rust", "typescript"]));
    assert_eq!(json_at_path(&project_value, "u16.limit"), &json!(1200));
    assert_eq!(project_value["version"], 1);

    for key in ["profile", "enforcement", "languages", "u16.limit"] {
        let output = guided_config_command(
            &home,
            &repo,
            &[
                "config", "reset", key, "--scope", "project", "--cwd", &repo_text,
            ],
        )
        .output()
        .expect("project config reset should run");
        assert!(output.status.success(), "{key}: {output:?}");
    }
    let project_value = serde_json::from_slice::<Value>(&fs::read(&project_path).unwrap())
        .expect("project config should remain JSON");
    assert!(project_value.get("profile").is_none());
    assert!(project_value.get("enforcement").is_none());
    assert!(project_value.get("languages").is_none());
    assert!(project_value.get("u16").is_none());
    assert_eq!(project_value["version"], 1);

    let _ = fs::remove_dir_all(root);
}

#[test]
fn guided_config_show_json_reports_all_source_layers_with_metadata() {
    let root = runtime_config_temp_dir("guided_show_sources");
    let home = root.join("home");
    let repo = root.join("repo");
    let user_path = home.join(".vibeguard/config.json");
    fs::create_dir_all(user_path.parent().unwrap()).expect("user config parent should exist");
    fs::create_dir_all(&repo).expect("repo should exist");
    assert!(
        Command::new("git")
            .args(["init", "-q"])
            .current_dir(&repo)
            .status()
            .expect("git init should run")
            .success()
    );
    fs::write(&user_path, r#"{"u16":{"warn_limit":450}}"#).expect("user config should be written");
    fs::write(repo.join(".vibeguard.json"), r#"{"u16":{"limit":900}}"#)
        .expect("project config should be written");
    let repo_text = repo.to_string_lossy().into_owned();

    let output = guided_config_command(
        &home,
        &repo,
        &["config", "show", "--cwd", &repo_text, "--json"],
    )
    .env_remove("VG_U16_WARN_LIMIT")
    .env_remove("VG_U16_LIMIT")
    .env("VG_CB_THRESHOLD", "9")
    .output()
    .expect("config show should run");
    assert!(output.status.success(), "{output:?}");
    let entries = serde_json::from_slice::<Vec<Value>>(&output.stdout)
        .expect("config show should emit JSON entries");
    let entry = |key: &str| {
        entries
            .iter()
            .find(|entry| entry["key"] == key)
            .unwrap_or_else(|| panic!("missing show entry for {key}"))
    };
    assert_eq!(entry("version")["source"], "default");
    assert_eq!(entry("u16.warn_limit")["source"], "user_config");
    assert_eq!(entry("u16.limit")["source"], "project_config");
    assert_eq!(entry("circuit_breaker.threshold")["source"], "environment");
    for item in &entries {
        assert!(
            item["category"]
                .as_str()
                .is_some_and(|text| !text.is_empty())
        );
        assert!(
            item["description"]
                .as_str()
                .is_some_and(|text| !text.is_empty())
        );
    }

    let _ = fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn guided_user_config_creation_and_replacement_are_private() {
    use std::os::unix::fs::PermissionsExt;

    let root = runtime_config_temp_dir("guided_private_user_config");
    let home = root.join("home");
    let repo = root.join("repo");
    fs::create_dir_all(&home).expect("home should exist");
    fs::create_dir_all(&repo).expect("repo should exist");
    let repo_text = repo.to_string_lossy().into_owned();
    let user_path = home.join(".vibeguard/config.json");

    let set = guided_config_command(
        &home,
        &repo,
        &[
            "config",
            "set",
            "u16.limit",
            "900",
            "--scope",
            "user",
            "--cwd",
            &repo_text,
        ],
    )
    .output()
    .expect("user config set should run");
    assert!(set.status.success(), "{set:?}");
    assert_eq!(
        fs::metadata(&user_path)
            .expect("user config should exist")
            .permissions()
            .mode()
            & 0o777,
        0o600
    );

    let reset = guided_config_command(
        &home,
        &repo,
        &[
            "config",
            "reset",
            "u16.limit",
            "--scope",
            "user",
            "--cwd",
            &repo_text,
        ],
    )
    .output()
    .expect("user config reset should run");
    assert!(reset.status.success(), "{reset:?}");
    assert_eq!(
        fs::metadata(&user_path)
            .expect("user config should remain")
            .permissions()
            .mode()
            & 0o777,
        0o600
    );

    fs::remove_file(&user_path).expect("user config should be removable");
    let init = guided_config_command(
        &home,
        &repo,
        &["config", "init", "--scope", "user", "--cwd", &repo_text],
    )
    .output()
    .expect("user config init should run");
    assert!(init.status.success(), "{init:?}");
    assert_eq!(
        fs::metadata(&user_path)
            .expect("initialized user config should exist")
            .permissions()
            .mode()
            & 0o777,
        0o600
    );

    let _ = fs::remove_dir_all(root);
}

#[test]
fn guided_config_invalid_set_and_reset_leave_existing_bytes_unchanged() {
    let root = runtime_config_temp_dir("guided_atomic_failure");
    let home = root.join("home");
    let repo = root.join("repo");
    let user_path = home.join(".vibeguard/config.json");
    fs::create_dir_all(&repo).expect("repo should be created");
    fs::create_dir_all(user_path.parent().unwrap()).expect("user config parent should be created");
    fs::write(
        &user_path,
        "{\n  \"version\": 1,\n  \"u16\": {\"limit\": 900}\n}\n",
    )
    .expect("user config should be written");
    let repo_text = repo.to_string_lossy().into_owned();

    let cases: Vec<Vec<&str>> = vec![
        vec![
            "config",
            "set",
            "u16.limit",
            "not-an-integer",
            "--scope",
            "user",
            "--cwd",
            &repo_text,
        ],
        vec![
            "config",
            "set",
            "churn.informational_edit_count",
            "11",
            "--scope",
            "user",
            "--cwd",
            &repo_text,
        ],
        vec![
            "config",
            "set",
            "churn.informational_edit_count",
            "0",
            "--scope",
            "user",
            "--cwd",
            &repo_text,
        ],
        vec![
            "config", "reset", "profile", "--scope", "user", "--cwd", &repo_text,
        ],
    ];
    for args in cases {
        let before = fs::read(&user_path).expect("user config should be readable");
        let output = guided_config_command(&home, &repo, &args)
            .output()
            .expect("invalid guided config command should run");
        assert_eq!(output.status.code(), Some(1), "{output:?}");
        assert!(!output.stdout.is_empty() || !output.stderr.is_empty());
        assert_eq!(
            fs::read(&user_path).expect("user config should remain readable"),
            before,
            "failed command changed user config for {args:?}"
        );
    }

    let _ = fs::remove_dir_all(root);
}

#[test]
fn guided_config_show_rejects_effective_churn_conflicts() {
    let root = runtime_config_temp_dir("guided_effective_churn_show");
    let home = root.join("home");
    let repo = root.join("repo");
    let user_path = home.join(".vibeguard/config.json");
    let project_path = repo.join(".vibeguard.json");
    fs::create_dir_all(user_path.parent().unwrap()).expect("user config parent should exist");
    fs::create_dir_all(&repo).expect("repo should exist");
    assert!(
        Command::new("git")
            .args(["init", "-q"])
            .current_dir(&repo)
            .status()
            .expect("git init should run")
            .success()
    );
    fs::write(
        &user_path,
        r#"{"churn":{"informational_edit_count":15,"warning_edit_count":15,"critical_edit_count":20}}"#,
    )
    .expect("user config should be written");
    fs::write(&project_path, r#"{"churn":{"warning_edit_count":12}}"#)
        .expect("project config should be written");
    let repo_text = repo.to_string_lossy().into_owned();

    let cross_layer = guided_config_command(
        &home,
        &repo,
        &["config", "show", "--cwd", &repo_text, "--json"],
    )
    .output()
    .expect("config show should run");
    assert_config_failure(&cross_layer, "config_range_error");

    fs::write(&user_path, "{}\n").expect("user config should be replaced");
    fs::write(&project_path, "{}\n").expect("project config should be replaced");
    let environment = guided_config_command(
        &home,
        &repo,
        &["config", "show", "--cwd", &repo_text, "--json"],
    )
    .env("VIBEGUARD_CHURN_INFORMATIONAL_EDIT_COUNT", "11")
    .output()
    .expect("config show should run");
    assert_config_failure(&environment, "config_range_error");

    let _ = fs::remove_dir_all(root);
}

#[test]
fn guided_config_show_accepts_valid_partial_churn_layers() {
    let root = runtime_config_temp_dir("guided_valid_partial_churn_layers");
    let home = root.join("home");
    let repo = root.join("repo");
    let user_path = home.join(".vibeguard/config.json");
    fs::create_dir_all(user_path.parent().unwrap()).expect("user config parent should exist");
    fs::create_dir_all(&repo).expect("repo should exist");
    assert!(
        Command::new("git")
            .args(["init", "-q"])
            .current_dir(&repo)
            .status()
            .expect("git init should run")
            .success()
    );
    fs::write(&user_path, r#"{"churn":{"informational_edit_count":15}}"#)
        .expect("user config should be written");
    fs::write(
        repo.join(".vibeguard.json"),
        r#"{"churn":{"warning_edit_count":20,"critical_edit_count":20}}"#,
    )
    .expect("project config should be written");
    let repo_text = repo.to_string_lossy().into_owned();

    let output = guided_config_command(
        &home,
        &repo,
        &["config", "show", "--cwd", &repo_text, "--json"],
    )
    .output()
    .expect("config show should run");
    assert!(output.status.success(), "{output:?}");
    let entries = serde_json::from_slice::<Vec<Value>>(&output.stdout)
        .expect("config show should emit JSON entries");
    let entry = |key: &str| {
        entries
            .iter()
            .find(|entry| entry["key"] == key)
            .unwrap_or_else(|| panic!("missing show entry for {key}"))
    };
    assert_eq!(entry("churn.informational_edit_count")["value"], 15);
    assert_eq!(
        entry("churn.informational_edit_count")["source"],
        "user_config"
    );
    assert_eq!(entry("churn.warning_edit_count")["value"], 20);
    assert_eq!(
        entry("churn.warning_edit_count")["source"],
        "project_config"
    );
    assert_eq!(entry("churn.critical_edit_count")["value"], 20);
    assert_eq!(
        entry("churn.critical_edit_count")["source"],
        "project_config"
    );

    let _ = fs::remove_dir_all(root);
}

#[test]
fn guided_user_set_rejects_effective_churn_conflict_without_writing() {
    let root = runtime_config_temp_dir("guided_effective_user_set");
    let home = root.join("home");
    let repo = root.join("repo");
    let user_path = home.join(".vibeguard/config.json");
    fs::create_dir_all(user_path.parent().unwrap()).expect("user config parent should exist");
    fs::create_dir_all(repo.join(".git")).expect("git marker should exist");
    fs::write(
        &user_path,
        "{\n  \"churn\": {\"informational_edit_count\": 5, \"warning_edit_count\": 15, \"critical_edit_count\": 20}\n}\n",
    )
    .expect("user config should be written");
    fs::write(
        repo.join(".vibeguard.json"),
        r#"{"churn":{"warning_edit_count":12}}"#,
    )
    .expect("project config should be written");
    let before = fs::read(&user_path).expect("user config should be readable");
    let repo_text = repo.to_string_lossy().into_owned();

    let output = guided_config_command(
        &home,
        &repo,
        &[
            "config",
            "set",
            "churn.informational_edit_count",
            "15",
            "--scope",
            "user",
            "--cwd",
            &repo_text,
        ],
    )
    .output()
    .expect("config set should run");
    assert_config_failure(&output, "config_range_error");
    assert_eq!(
        fs::read(&user_path).expect("user config should remain readable"),
        before
    );

    let _ = fs::remove_dir_all(root);
}

#[test]
fn guided_project_set_rejects_effective_churn_conflict_without_writing() {
    let root = runtime_config_temp_dir("guided_effective_project_set");
    let home = root.join("home");
    let repo = root.join("repo");
    let user_path = home.join(".vibeguard/config.json");
    let project_path = repo.join(".vibeguard.json");
    fs::create_dir_all(user_path.parent().unwrap()).expect("user config parent should exist");
    fs::create_dir_all(repo.join(".git")).expect("git marker should exist");
    fs::write(
        &user_path,
        r#"{"churn":{"informational_edit_count":9,"warning_edit_count":15,"critical_edit_count":20}}"#,
    )
    .expect("user config should be written");
    fs::write(
        &project_path,
        "{\n  \"churn\": {\"warning_edit_count\": 12}\n}\n",
    )
    .expect("project config should be written");
    let before = fs::read(&project_path).expect("project config should be readable");
    let repo_text = repo.to_string_lossy().into_owned();

    let output = guided_config_command(
        &home,
        &repo,
        &[
            "config",
            "set",
            "churn.warning_edit_count",
            "8",
            "--scope",
            "project",
            "--cwd",
            &repo_text,
        ],
    )
    .output()
    .expect("config set should run");
    assert_config_failure(&output, "config_range_error");
    assert_eq!(
        fs::read(&project_path).expect("project config should remain readable"),
        before
    );

    let _ = fs::remove_dir_all(root);
}
