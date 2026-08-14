mod common;

use common::{bin, unique_temp_dir};
use std::fs;
use std::path::PathBuf;
#[cfg(unix)]
use std::process::Command;

fn codex_setup_fixture(label: &str, manifest: Option<&str>) -> (PathBuf, PathBuf, Vec<u8>) {
    let repo = unique_temp_dir(label);
    let hooks_dir = repo.join("hooks");
    fs::create_dir_all(&hooks_dir).unwrap();
    if let Some(manifest) = manifest {
        fs::write(hooks_dir.join("manifest.json"), manifest).unwrap();
    }
    let hooks_file = repo.join("codex-hooks.json");
    fs::write(
        &hooks_file,
        r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash /missing/run-hook-codex.sh vibeguard-pre-bash-guard.sh",
            "timeout": 15
          },
          {
            "type": "command",
            "command": "bash /missing/third-party.sh",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
"#,
    )
    .unwrap();
    let before = fs::read(&hooks_file).unwrap();
    (repo, hooks_file, before)
}

fn profiled_codex_manifest() -> String {
    serde_json::json!({
        "schema_version": 1,
        "profiles": ["minimal", "core", "full", "strict"],
        "hooks": [
            {
                "name": "pre-bash-guard",
                "script": "pre-bash-guard.sh",
                "kind": "hook",
                "trigger": "PreToolUse(Bash)",
                "responsibilities": "test fixture",
                "decision_types": ["block"],
                "claude": {
                    "enabled": true,
                    "profiles": ["minimal", "core", "full", "strict"]
                },
                "codex": {
                    "enabled": true,
                    "script": "vibeguard-pre-bash-guard.sh",
                    "timeout": 15,
                    "entries": [
                        {"event": "PreToolUse", "matcher": "Bash"},
                        {"event": "PermissionRequest", "matcher": "Bash"}
                    ]
                }
            },
            {
                "name": "pre-edit-guard",
                "script": "pre-edit-guard.sh",
                "kind": "hook",
                "trigger": "PreToolUse(Edit)",
                "responsibilities": "test fixture",
                "decision_types": ["block"],
                "claude": {
                    "enabled": true,
                    "profiles": ["minimal", "core", "full", "strict"]
                },
                "codex": {
                    "enabled": true,
                    "script": "vibeguard-pre-edit-guard.sh",
                    "timeout": 15,
                    "entries": [
                        {"event": "PreToolUse", "matcher": "Edit"},
                        {"event": "PermissionRequest", "matcher": "Edit"}
                    ]
                }
            },
            {
                "name": "pre-write-guard",
                "script": "pre-write-guard.sh",
                "kind": "hook",
                "trigger": "PreToolUse(Write)",
                "responsibilities": "test fixture",
                "decision_types": ["warn"],
                "claude": {
                    "enabled": true,
                    "profiles": ["minimal", "core", "full", "strict"]
                },
                "codex": {
                    "enabled": true,
                    "script": "vibeguard-pre-write-guard.sh",
                    "timeout": 15,
                    "entries": [
                        {"event": "PreToolUse", "matcher": "Write"},
                        {"event": "PermissionRequest", "matcher": "Write"}
                    ]
                }
            },
            {
                "name": "post-build-check",
                "script": "post-build-check.sh",
                "kind": "hook",
                "trigger": "PostToolUse(Edit/Write)",
                "responsibilities": "test fixture",
                "decision_types": ["warn"],
                "claude": {
                    "enabled": true,
                    "profiles": ["full", "strict"]
                },
                "codex": {
                    "enabled": true,
                    "script": "vibeguard-post-build-check.sh",
                    "timeout": 35,
                    "entries": [
                        {"event": "PostToolUse", "matcher": "Bash"},
                        {"event": "PostToolUse", "matcher": "Edit|Write"}
                    ]
                }
            },
            {
                "name": "stop-guard",
                "script": "stop-guard.sh",
                "kind": "hook",
                "trigger": "Stop",
                "responsibilities": "test fixture",
                "decision_types": ["gate"],
                "claude": {
                    "enabled": true,
                    "profiles": ["full", "strict"]
                },
                "codex": {
                    "enabled": true,
                    "event": "Stop",
                    "matcher": null,
                    "script": "vibeguard-stop-guard.sh",
                    "timeout": 15
                }
            }
        ]
    })
    .to_string()
}

#[test]
fn codex_hooks_upsert_filters_profile_and_tags_runtime_policy_profile() {
    let manifest = profiled_codex_manifest();
    for profile in ["minimal", "core", "full", "strict"] {
        let (repo, hooks_file, _) =
            codex_setup_fixture(&format!("profile-upsert-{profile}"), Some(&manifest));
        fs::write(&hooks_file, "{}").unwrap();
        let wrapper = repo.join(".vibeguard/run-hook-codex.sh");
        fs::create_dir_all(wrapper.parent().unwrap()).unwrap();
        fs::write(&wrapper, "#!/usr/bin/env bash\n").unwrap();

        let output = bin()
            .arg("setup-codex-hooks-upsert")
            .arg(&repo)
            .arg(&hooks_file)
            .arg(&wrapper)
            .arg(profile)
            .output()
            .unwrap();

        assert!(output.status.success(), "{profile}: {output:?}");
        assert_eq!(String::from_utf8_lossy(&output.stdout), "CHANGED\n");
        let text = fs::read_to_string(&hooks_file).unwrap();
        assert!(text.contains(&format!(
            "VIBEGUARD_PROFILE=\\\"${{VIBEGUARD_PROFILE:-{profile}}}\\\""
        )));
        for script in [
            "vibeguard-pre-bash-guard.sh",
            "vibeguard-pre-edit-guard.sh",
            "vibeguard-pre-write-guard.sh",
        ] {
            assert!(text.contains(script), "{profile} missing {script}: {text}");
        }
        let has_full_hooks = text.contains("vibeguard-stop-guard.sh")
            || text.contains("vibeguard-post-build-check.sh");
        assert_eq!(
            has_full_hooks,
            matches!(profile, "full" | "strict"),
            "{profile}: {text}"
        );

        let check = bin()
            .arg("setup-codex-hooks-check")
            .arg(&repo)
            .arg(&hooks_file)
            .arg(&wrapper)
            .arg(profile)
            .output()
            .unwrap();
        assert!(check.status.success(), "{profile}: {check:?}");
        fs::remove_dir_all(repo).unwrap();
    }
}

#[cfg(unix)]
#[test]
fn codex_generated_command_preserves_caller_and_project_profile_precedence() {
    let manifest = profiled_codex_manifest();
    let (repo, hooks_file, _) = codex_setup_fixture("profile-command-precedence", Some(&manifest));
    fs::write(&hooks_file, "{}").unwrap();
    let wrapper = repo.join("run-policy-wrapper.sh");
    fs::write(
        &wrapper,
        r#"#!/usr/bin/env bash
set -euo pipefail
exec "${VIBEGUARD_RUNTIME_TEST_BIN}" runtime-policy-check --cwd "${VIBEGUARD_RUNTIME_TEST_CWD}" "$1"
"#,
    )
    .unwrap();

    let upsert = bin()
        .arg("setup-codex-hooks-upsert")
        .arg(&repo)
        .arg(&hooks_file)
        .arg(&wrapper)
        .arg("full")
        .output()
        .unwrap();
    assert!(upsert.status.success(), "{upsert:?}");

    let data: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&hooks_file).unwrap()).unwrap();
    let command = data
        .pointer("/hooks/Stop/0/hooks/0/command")
        .and_then(serde_json::Value::as_str)
        .expect("full profile should generate a Stop command")
        .to_string();
    let project = repo.join("project");
    fs::create_dir_all(&project).unwrap();

    let run_command = |caller_profile: Option<&str>| {
        let mut process = Command::new("bash");
        process
            .arg("-c")
            .arg(&command)
            .current_dir(&project)
            .env(
                "VIBEGUARD_RUNTIME_TEST_BIN",
                env!("CARGO_BIN_EXE_vibeguard-runtime"),
            )
            .env("VIBEGUARD_RUNTIME_TEST_CWD", &project)
            .env_remove("VIBEGUARD_PROJECT_CONFIG")
            .env_remove("VIBEGUARD_USER_CONFIG_FILE");
        match caller_profile {
            Some(profile) => {
                process.env("VIBEGUARD_PROFILE", profile);
            }
            None => {
                process.env_remove("VIBEGUARD_PROFILE");
            }
        }
        process.output().unwrap()
    };

    let installed_fallback = run_command(None);
    assert!(
        installed_fallback.status.success(),
        "{installed_fallback:?}"
    );
    let fallback_json: serde_json::Value =
        serde_json::from_slice(&installed_fallback.stdout).unwrap();
    assert_eq!(fallback_json["profile"], "full");
    assert_eq!(fallback_json["decision"], "run");

    let caller_override = run_command(Some("core"));
    assert_eq!(
        caller_override.status.code(),
        Some(10),
        "{caller_override:?}"
    );
    let caller_json: serde_json::Value = serde_json::from_slice(&caller_override.stdout).unwrap();
    assert_eq!(caller_json["profile"], "core");
    assert_eq!(caller_json["decision"], "skip");

    fs::write(project.join(".vibeguard.json"), r#"{"profile":"strict"}"#).unwrap();
    let project_override = run_command(Some("core"));
    assert!(project_override.status.success(), "{project_override:?}");
    let project_json: serde_json::Value = serde_json::from_slice(&project_override.stdout).unwrap();
    assert_eq!(project_json["profile"], "strict");
    assert_eq!(project_json["decision"], "run");

    fs::remove_dir_all(repo).unwrap();
}

#[test]
fn codex_hooks_profile_downgrade_removes_full_only_hooks() {
    let manifest = profiled_codex_manifest();
    let (repo, hooks_file, _) = codex_setup_fixture("profile-downgrade", Some(&manifest));
    fs::write(&hooks_file, "{}").unwrap();
    let wrapper = repo.join(".vibeguard/run-hook-codex.sh");
    fs::create_dir_all(wrapper.parent().unwrap()).unwrap();
    fs::write(&wrapper, "#!/usr/bin/env bash\n").unwrap();

    let full = bin()
        .arg("setup-codex-hooks-upsert")
        .arg(&repo)
        .arg(&hooks_file)
        .arg(&wrapper)
        .arg("full")
        .output()
        .unwrap();
    assert!(full.status.success(), "{full:?}");
    assert!(
        fs::read_to_string(&hooks_file)
            .unwrap()
            .contains("vibeguard-stop-guard.sh")
    );

    let core = bin()
        .arg("setup-codex-hooks-upsert")
        .arg(&repo)
        .arg(&hooks_file)
        .arg(&wrapper)
        .arg("core")
        .output()
        .unwrap();
    assert!(core.status.success(), "{core:?}");
    let text = fs::read_to_string(&hooks_file).unwrap();
    assert!(!text.contains("vibeguard-stop-guard.sh"), "{text}");
    assert!(!text.contains("vibeguard-post-build-check.sh"), "{text}");
    assert!(text.contains("vibeguard-pre-bash-guard.sh"), "{text}");
    fs::remove_dir_all(repo).unwrap();
}

#[test]
fn codex_hooks_check_rejects_out_of_profile_managed_hooks() {
    let manifest = profiled_codex_manifest();
    let (repo, hooks_file, _) = codex_setup_fixture("profile-check-extra", Some(&manifest));
    fs::write(&hooks_file, "{}").unwrap();
    let wrapper = repo.join(".vibeguard/run-hook-codex.sh");
    fs::create_dir_all(wrapper.parent().unwrap()).unwrap();
    fs::write(&wrapper, "#!/usr/bin/env bash\n").unwrap();

    let core = bin()
        .arg("setup-codex-hooks-upsert")
        .arg(&repo)
        .arg(&hooks_file)
        .arg(&wrapper)
        .arg("core")
        .output()
        .unwrap();
    assert!(core.status.success(), "{core:?}");

    let mut data: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&hooks_file).unwrap()).unwrap();
    data["hooks"]["Stop"] = serde_json::json!([
        {
            "hooks": [
                {
                    "type": "command",
                    "command": format!(
                        "env VIBEGUARD_PROFILE=\"${{VIBEGUARD_PROFILE:-full}}\" bash {} vibeguard-stop-guard.sh",
                        wrapper.display()
                    ),
                    "timeout": 15
                }
            ]
        }
    ]);
    fs::write(&hooks_file, serde_json::to_string_pretty(&data).unwrap()).unwrap();

    let check = bin()
        .arg("setup-codex-hooks-check")
        .arg(&repo)
        .arg(&hooks_file)
        .arg(&wrapper)
        .arg("core")
        .output()
        .unwrap();
    assert!(!check.status.success(), "{check:?}");
    fs::remove_dir_all(repo).unwrap();
}
