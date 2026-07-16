use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_ID: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    repo: PathBuf,
    home: PathBuf,
    home_env: String,
}

impl Fixture {
    fn new(label: &str) -> Self {
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "vibeguard-setup-settings-{label}-{}-{id}",
            std::process::id()
        ));
        let repo = root.join("repo");
        let home = root.join("home");
        fs::create_dir_all(repo.join("hooks")).expect("hook fixture directory should be created");
        fs::create_dir_all(&home).expect("fixture HOME should be created");
        let home_env = slash_path(&home);
        Self {
            root,
            repo,
            home,
            home_env,
        }
    }

    fn settings(&self, name: &str) -> PathBuf {
        self.home.join(name)
    }

    fn write_manifest(&self, manifest: &Value) {
        fs::write(
            self.repo.join("hooks/manifest.json"),
            serde_json::to_vec(manifest).unwrap(),
        )
        .expect("hook manifest should be written");
    }

    fn write_settings(&self, name: &str, settings: &Value) -> PathBuf {
        let path = self.settings(name);
        fs::write(&path, serde_json::to_vec_pretty(settings).unwrap())
            .expect("settings should be written");
        path
    }

    fn command(&self, name: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"));
        command
            .arg(name)
            .current_dir(&self.repo)
            .env("HOME", &self.home_env);
        command
    }

    fn wrapper_command(&self, script: &str) -> String {
        format!("bash {}/.vibeguard/run-hook.sh {script}", self.home_env)
    }

    fn cleanup(self) {
        fs::remove_dir_all(self.root).expect("fixture should be removed");
    }
}

fn slash_path(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8(bytes.to_vec()).expect("command output should be UTF-8")
}

fn assert_success(output: &Output, expected_stdout: &str) {
    assert_eq!(
        output.status.code(),
        Some(0),
        "stderr={}",
        text(&output.stderr)
    );
    assert_eq!(text(&output.stdout), expected_stdout);
    assert_eq!(text(&output.stderr), "");
}

fn assert_mismatch(output: &Output) {
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(text(&output.stdout), "");
    assert_eq!(text(&output.stderr), "");
}

fn assert_visible_failure(output: &Output, stable_message: Option<&str>) {
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(text(&output.stdout), "");
    let error = text(&output.stderr);
    assert!(
        error.starts_with("vibeguard-runtime error: "),
        "unexpected stderr: {error}"
    );
    if let Some(message) = stable_message {
        assert!(error.contains(message), "stderr={error}");
    }
}

fn full_manifest() -> Value {
    json!({
        "hooks": [
            {
                "script": "pre-a.sh",
                "claude": {
                    "enabled": true,
                    "event": "PreToolUse",
                    "matchers": ["Bash"],
                    "profiles": ["minimal", "core", "full", "strict"]
                }
            },
            {
                "script": "post-a.sh",
                "claude": {
                    "enabled": true,
                    "event": "PostToolUse",
                    "matchers": ["Edit"],
                    "profiles": ["minimal", "core", "full", "strict"]
                }
            },
            {
                "script": "full-a.sh",
                "claude": {
                    "enabled": true,
                    "event": "Stop",
                    "matchers": [""],
                    "profiles": ["full", "strict"]
                }
            },
            {
                "script": "strict-a.sh",
                "claude": {
                    "enabled": true,
                    "event": "SessionStart",
                    "matchers": [""],
                    "profiles": ["strict"]
                }
            },
            {"script": "disabled.sh", "claude": {"enabled": false}}
        ]
    })
}

fn single_manifest() -> Value {
    json!({
        "hooks": [{
            "script": "pre-a.sh",
            "claude": {
                "enabled": true,
                "event": "PreToolUse",
                "matchers": ["Bash"],
                "profiles": ["minimal", "core", "full", "strict"]
            }
        }]
    })
}

fn hook_entry(matcher: &str, commands: &[String]) -> Value {
    json!({
        "matcher": matcher,
        "hooks": commands
            .iter()
            .map(|command| json!({"type": "command", "command": command}))
            .collect::<Vec<_>>()
    })
}

fn core_settings(fixture: &Fixture) -> Value {
    json!({
        "hooks": {
            "PreToolUse": [hook_entry("Bash", &[fixture.wrapper_command("pre-a.sh")])],
            "PostToolUse": [hook_entry("Edit", &[fixture.wrapper_command("post-a.sh")])]
        }
    })
}

fn invoke_settings_check(fixture: &Fixture, settings: &Path, target: &str) -> Output {
    fixture
        .command("setup-settings-check")
        .arg(&fixture.repo)
        .arg(settings)
        .arg(target)
        .output()
        .expect("settings check should run")
}

fn invoke_settings_upsert(
    fixture: &Fixture,
    settings: &Path,
    profile: &str,
    flags: &[&str],
) -> Output {
    fixture
        .command("setup-settings-upsert")
        .arg(&fixture.repo)
        .arg(settings)
        .arg(profile)
        .args(flags)
        .output()
        .expect("settings upsert should run")
}

fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).expect("settings should be readable"))
        .expect("settings should be JSON")
}

#[test]
fn settings_check_distinguishes_valid_missing_unsupported_duplicate_and_extra_hooks() {
    let fixture = Fixture::new("check");
    fixture.write_manifest(&full_manifest());
    let settings = fixture.write_settings("settings.json", &core_settings(&fixture));

    for target in ["pre-hooks", "post-hooks", "profile-hooks:core"] {
        assert_success(&invoke_settings_check(&fixture, &settings, target), "");
    }

    let missing = fixture.settings("missing.json");
    assert_visible_failure(
        &invoke_settings_check(&fixture, &missing, "profile-hooks:core"),
        None,
    );
    assert_visible_failure(
        &invoke_settings_check(&fixture, &settings, "profile-hooks:unknown"),
        Some("unsupported profile target: unknown"),
    );

    let mut incomplete = core_settings(&fixture);
    incomplete["hooks"]
        .as_object_mut()
        .unwrap()
        .remove("PostToolUse");
    fixture.write_settings("settings.json", &incomplete);
    assert_mismatch(&invoke_settings_check(
        &fixture,
        &settings,
        "profile-hooks:core",
    ));

    let mut duplicate = core_settings(&fixture);
    duplicate["hooks"]["PreToolUse"]
        .as_array_mut()
        .unwrap()
        .push(hook_entry("Bash", &[fixture.wrapper_command("pre-a.sh")]));
    fixture.write_settings("settings.json", &duplicate);
    assert_mismatch(&invoke_settings_check(
        &fixture,
        &settings,
        "profile-hooks:core",
    ));

    let mut extra = core_settings(&fixture);
    extra["hooks"].as_object_mut().unwrap().insert(
        "Stop".to_string(),
        json!([hook_entry("", &[fixture.wrapper_command("full-a.sh")])]),
    );
    fixture.write_settings("settings.json", &extra);
    assert_mismatch(&invoke_settings_check(
        &fixture,
        &settings,
        "profile-hooks:core",
    ));
    fixture.cleanup();
}

#[test]
fn settings_upsert_dry_run_actual_and_repeat_are_deterministic() {
    let fixture = Fixture::new("upsert");
    fixture.write_manifest(&full_manifest());
    let settings = fixture.settings("settings.json");

    let dry_run = invoke_settings_upsert(&fixture, &settings, "core", &["--dry-run"]);
    assert_eq!(dry_run.status.code(), Some(0));
    let dry_stdout = text(&dry_run.stdout);
    assert!(dry_stdout.contains("--- "), "stdout={dry_stdout}");
    assert!(dry_stdout.ends_with("CHANGED\n"), "stdout={dry_stdout}");
    assert!(!settings.exists());

    assert_success(
        &invoke_settings_upsert(&fixture, &settings, "core", &[]),
        "CHANGED\n",
    );
    let value = read_json(&settings);
    let rendered = serde_json::to_string(&value).unwrap();
    assert!(rendered.contains(&fixture.wrapper_command("pre-a.sh")));
    assert!(rendered.contains(&fixture.wrapper_command("post-a.sh")));
    assert!(!rendered.contains("full-a.sh"));
    assert!(!rendered.contains("strict-a.sh"));
    let before_repeat = fs::read(&settings).unwrap();
    assert_success(
        &invoke_settings_upsert(&fixture, &settings, "core", &["--dry-run"]),
        "SKIP\n",
    );
    assert_eq!(fs::read(&settings).unwrap(), before_repeat);
    assert_success(
        &invoke_settings_upsert(&fixture, &settings, "core", &[]),
        "SKIP\n",
    );
    assert_eq!(fs::read(&settings).unwrap(), before_repeat);
    fixture.cleanup();
}

#[test]
fn settings_upsert_preserves_custom_commands_unless_force_is_explicit() {
    let fixture = Fixture::new("custom");
    fixture.write_manifest(&single_manifest());
    let custom = "env VG_CUSTOM=1 /custom/run-hook.sh pre-a.sh".to_string();
    let settings = fixture.write_settings(
        "settings.json",
        &json!({"hooks": {"PreToolUse": [hook_entry("Bash", std::slice::from_ref(&custom))]}}),
    );

    let preserve = invoke_settings_upsert(&fixture, &settings, "core", &[]);
    assert_eq!(preserve.status.code(), Some(0));
    assert_eq!(text(&preserve.stdout), "SKIP\n");
    assert!(text(&preserve.stderr).contains("preserving customized VibeGuard hook command"));
    assert!(
        serde_json::to_string(&read_json(&settings))
            .unwrap()
            .contains(&custom)
    );

    assert_success(
        &invoke_settings_upsert(&fixture, &settings, "core", &["--force-overwrite"]),
        "CHANGED\n",
    );
    let rendered = serde_json::to_string(&read_json(&settings)).unwrap();
    assert!(!rendered.contains("VG_CUSTOM"));
    assert!(rendered.contains(&fixture.wrapper_command("pre-a.sh")));
    fixture.cleanup();
}

#[test]
fn settings_remove_preserves_unmanaged_hooks_and_upsert_cleans_stale_installed_hooks() {
    let fixture = Fixture::new("remove");
    fixture.write_manifest(&full_manifest());
    let unmanaged = "node /custom/audit.js".to_string();
    let settings = fixture.write_settings(
        "settings.json",
        &json!({
            "hooks": {
                "PreToolUse": [hook_entry(
                    "Bash",
                    &[fixture.wrapper_command("pre-a.sh"), unmanaged.clone()]
                )],
                "PostToolUse": [hook_entry("Edit", &[fixture.wrapper_command("post-a.sh")])]
            }
        }),
    );

    let removed = fixture
        .command("setup-settings-remove")
        .arg(&fixture.repo)
        .arg(&settings)
        .output()
        .unwrap();
    assert_success(&removed, "CHANGED\n");
    let rendered = serde_json::to_string(&read_json(&settings)).unwrap();
    assert!(rendered.contains(&unmanaged));
    assert!(!rendered.contains("pre-a.sh"));
    assert!(!rendered.contains("post-a.sh"));

    let second = fixture
        .command("setup-settings-remove")
        .arg(&fixture.repo)
        .arg(&settings)
        .output()
        .unwrap();
    assert_success(&second, "SKIP\n");
    let missing = fixture.settings("absent.json");
    let missing_remove = fixture
        .command("setup-settings-remove")
        .arg(&fixture.repo)
        .arg(&missing)
        .output()
        .unwrap();
    assert_success(&missing_remove, "SKIP\n");

    fixture.write_manifest(&single_manifest());
    let stale = "bash ~/.vibeguard/installed/hooks/old.sh".to_string();
    fixture.write_settings(
        "settings.json",
        &json!({"hooks": {"PostToolUse": [hook_entry("Edit", &[stale, unmanaged.clone()])]}}),
    );
    assert_success(
        &invoke_settings_upsert(&fixture, &settings, "core", &[]),
        "CHANGED\n",
    );
    let repaired = serde_json::to_string(&read_json(&settings)).unwrap();
    assert!(!repaired.contains("old.sh"));
    assert!(repaired.contains(&unmanaged));
    assert!(repaired.contains("pre-a.sh"));
    fixture.cleanup();
}

#[test]
fn stale_check_distinguishes_direct_existing_wrapper_missing_and_unresolved_commands() {
    let fixture = Fixture::new("stale");
    let installed = fixture.home.join(".vibeguard/installed/hooks");
    fs::create_dir_all(&installed).unwrap();
    fs::write(installed.join("existing.sh"), "#!/bin/sh\n").unwrap();
    fs::write(installed.join("legacy.sh"), "#!/bin/sh\n").unwrap();
    let settings = fixture.write_settings(
        "settings.json",
        &json!({
            "hooks": {
                "PostToolUse": [{
                    "matcher": "Edit",
                    "hooks": [
                        {"command": "bash ~/.vibeguard/installed/hooks/legacy.sh"},
                        {"command": "bash ~/.vibeguard/installed/hooks/direct-missing.sh"},
                        {"command": "~/.vibeguard/run-hook.sh existing.sh"},
                        {"command": "~/.vibeguard/run-hook.sh missing.sh"},
                        {"command": "~/.vibeguard/run-hook.sh nested/unresolved.sh"},
                        {"command": "node /custom/audit.js"}
                    ]
                }]
            }
        }),
    );

    let stale = fixture
        .command("setup-settings-check-stale")
        .arg(&settings)
        .output()
        .unwrap();
    assert_eq!(stale.status.code(), Some(1));
    assert_eq!(text(&stale.stderr), "");
    let findings = text(&stale.stdout);
    let expected_findings = format!(
        concat!(
            "stale Claude hook command: config=~/settings.json event=PostToolUse matcher=Edit command_path={} repair=bash setup.sh --yes\n",
            "stale Claude hook command: config=~/settings.json event=PostToolUse matcher=Edit command_path={} repair=bash setup.sh --yes\n",
            "stale Claude hook command: config=~/settings.json event=PostToolUse matcher=Edit command_path={} repair=bash setup.sh --yes\n"
        ),
        installed.join("legacy.sh").display(),
        installed.join("direct-missing.sh").display(),
        installed.join("missing.sh").display(),
    );
    assert_eq!(findings, expected_findings);

    fixture.write_settings(
        "settings.json",
        &json!({"hooks": {"PostToolUse": [hook_entry(
            "Edit",
            &["~/.vibeguard/run-hook.sh existing.sh".to_string()]
        )]}}),
    );
    let clean = fixture
        .command("setup-settings-check-stale")
        .arg(&settings)
        .output()
        .unwrap();
    assert_success(&clean, "");
    let missing = fixture.settings("missing.json");
    let absent = fixture
        .command("setup-settings-check-stale")
        .arg(missing)
        .output()
        .unwrap();
    assert_success(&absent, "");
    fixture.cleanup();
}

#[test]
fn settings_argument_manifest_read_and_write_errors_are_visible() {
    let fixture = Fixture::new("errors");
    for command in [
        "setup-settings-check",
        "setup-settings-upsert",
        "setup-settings-remove",
        "setup-settings-check-stale",
    ] {
        let output = fixture.command(command).output().unwrap();
        assert_visible_failure(&output, Some("Usage: vibeguard-runtime setup-settings-"));
    }

    fixture.write_manifest(&json!({}));
    let settings = fixture.write_settings("settings.json", &json!({}));
    assert_visible_failure(
        &invoke_settings_upsert(&fixture, &settings, "core", &[]),
        Some("hooks manifest must contain a hooks array"),
    );

    fixture.write_manifest(&single_manifest());
    let blocking_parent = fixture.settings("not-a-directory");
    fs::write(&blocking_parent, "blocking file\n").unwrap();
    let blocked_settings = blocking_parent.join("settings.json");
    assert_visible_failure(
        &invoke_settings_upsert(&fixture, &blocked_settings, "core", &[]),
        None,
    );
    let directory_settings = fixture.settings("directory-settings");
    fs::create_dir_all(&directory_settings).unwrap();
    assert_visible_failure(
        &invoke_settings_check(&fixture, &directory_settings, "profile-hooks:core"),
        None,
    );
    fixture.cleanup();
}
