mod common;

use common::{bin, run_runtime_with_stdin, unique_temp_dir};
use std::fs;
use std::path::{Path, PathBuf};

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

fn run_codex_setup(command: &str, repo: &Path, hooks_file: &Path) -> std::process::Output {
    bin()
        .arg(command)
        .arg(repo)
        .arg(hooks_file)
        .output()
        .unwrap()
}

fn valid_codex_manifest(timeout: i64) -> String {
    serde_json::json!({
        "schema_version": 1,
        "profiles": ["core"],
        "hooks": [
            {
                "name": "pre-bash-guard",
                "script": "pre-bash-guard.sh",
                "kind": "hook",
                "trigger": "PreToolUse(Bash)",
                "responsibilities": "test fixture",
                "decision_types": ["block"],
                "claude": { "enabled": false },
                "codex": {
                    "enabled": true,
                    "event": "PreToolUse",
                    "matcher": "Bash",
                    "script": "vibeguard-pre-bash-guard.sh",
                    "timeout": timeout
                }
            }
        ]
    })
    .to_string()
}

fn assert_manifest_failure(output: &std::process::Output) {
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("manifest.json"),
        "stderr did not identify the manifest: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn codex_event_name_extracts_event_and_tolerates_invalid_json() {
    let out = run_runtime_with_stdin(
        &["codex-event-name"],
        r#"{"hook_event_name":"PermissionRequest"}"#,
    );
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "PermissionRequest\n");

    let invalid = run_runtime_with_stdin(&["codex-event-name"], "{not-json");
    assert_eq!(invalid.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&invalid.stdout), "\n");
}

#[test]
fn codex_status_helpers_extract_matcher_and_detail() {
    let payload =
        r#"{"tool_name":"Bash","tool_input":{"file_path":"src/lib.rs","command":"cargo test"}}"#;
    let matcher = run_runtime_with_stdin(&["codex-status-matcher"], payload);
    assert_eq!(matcher.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&matcher.stdout), "Bash\n");

    let detail = run_runtime_with_stdin(&["codex-status-detail"], payload);
    assert_eq!(detail.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&detail.stdout), "src/lib.rs\n");

    let command_detail = run_runtime_with_stdin(
        &["codex-status-detail"],
        r#"{"tool_input":{"command":"rg TODO"}}"#,
    );
    assert_eq!(command_detail.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&command_detail.stdout), "rg TODO\n");
}

#[test]
fn codex_status_from_output_maps_decisions_and_invalid_json() {
    let block = run_runtime_with_stdin(
        &["codex-status-from-output"],
        r#"{"decision":"block","reason":"no"}"#,
    );
    assert_eq!(block.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&block.stdout), "block\tno\n");

    let nested = run_runtime_with_stdin(
        &["codex-status-from-output"],
        r#"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"stop"}}}"#,
    );
    assert_eq!(nested.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&nested.stdout), "block\t\n");

    let invalid = run_runtime_with_stdin(&["codex-status-from-output"], "{not-json");
    assert_eq!(invalid.status.code(), Some(0));
    assert_eq!(
        String::from_utf8_lossy(&invalid.stdout),
        "hook_error\tinvalid-json\n"
    );
}

#[test]
fn codex_deny_helpers_emit_native_deny_payloads() {
    let pretool = run_runtime_with_stdin(&["codex-pretool-deny"], "blocked");
    assert_eq!(pretool.status.code(), Some(0));
    let pretool_json: serde_json::Value = serde_json::from_slice(&pretool.stdout).unwrap();
    assert_eq!(
        pretool_json["hookSpecificOutput"]["permissionDecision"],
        "deny"
    );
    assert_eq!(
        pretool_json["hookSpecificOutput"]["permissionDecisionReason"],
        "blocked"
    );

    let permission = run_runtime_with_stdin(&["codex-permission-deny"], "blocked");
    assert_eq!(permission.status.code(), Some(0));
    let permission_json: serde_json::Value = serde_json::from_slice(&permission.stdout).unwrap();
    assert_eq!(
        permission_json["hookSpecificOutput"]["decision"]["behavior"],
        "deny"
    );
    assert_eq!(
        permission_json["hookSpecificOutput"]["decision"]["message"],
        "blocked"
    );
}

#[test]
fn codex_adapter_commands_map_wrapped_outputs() {
    let pretool = run_runtime_with_stdin(
        &["codex-adapt-pretool"],
        r#"{"decision":"block","reason":"force push denied"}"#,
    );
    assert_eq!(pretool.status.code(), Some(0));
    let pretool_json: serde_json::Value = serde_json::from_slice(&pretool.stdout).unwrap();
    assert_eq!(
        pretool_json["hookSpecificOutput"]["permissionDecision"],
        "deny"
    );
    assert_eq!(
        pretool_json["hookSpecificOutput"]["permissionDecisionReason"],
        "force push denied"
    );

    let rewrite = run_runtime_with_stdin(
        &["codex-adapt-pretool"],
        r#"{"decision":"allow","updatedInput":{"command":"pnpm install"}}"#,
    );
    assert_eq!(rewrite.status.code(), Some(0));
    let rewrite_json: serde_json::Value = serde_json::from_slice(&rewrite.stdout).unwrap();
    assert!(
        rewrite_json["systemMessage"]
            .as_str()
            .unwrap()
            .contains("pnpm install")
    );

    let posttool = run_runtime_with_stdin(
        &["codex-adapt-posttool"],
        r#"{"decision":"escalate","reason":"build failed"}"#,
    );
    assert_eq!(posttool.status.code(), Some(0));
    let posttool_json: serde_json::Value = serde_json::from_slice(&posttool.stdout).unwrap();
    assert_eq!(posttool_json["decision"], "block");
    assert_eq!(
        posttool_json["hookSpecificOutput"]["additionalContext"],
        "build failed"
    );

    let permission = run_runtime_with_stdin(
        &["codex-adapt-permission-request"],
        r#"{"decision":"block","reason":"permission denied"}"#,
    );
    assert_eq!(permission.status.code(), Some(0));
    let permission_json: serde_json::Value = serde_json::from_slice(&permission.stdout).unwrap();
    assert_eq!(
        permission_json["hookSpecificOutput"]["decision"]["behavior"],
        "deny"
    );
    assert_eq!(
        permission_json["hookSpecificOutput"]["decision"]["message"],
        "permission denied"
    );
}

#[test]
fn codex_adapter_commands_fail_closed_on_invalid_json() {
    let pretool = run_runtime_with_stdin(&["codex-adapt-pretool"], "{not-json");
    assert_eq!(pretool.status.code(), Some(3));
    let pretool_json: serde_json::Value = serde_json::from_slice(&pretool.stdout).unwrap();
    assert_eq!(
        pretool_json["hookSpecificOutput"]["permissionDecision"],
        "deny"
    );

    let posttool = run_runtime_with_stdin(&["codex-adapt-posttool"], "{not-json");
    assert_eq!(posttool.status.code(), Some(3));
    assert!(posttool.stdout.is_empty());

    let permission = run_runtime_with_stdin(&["codex-adapt-permission-request"], "{not-json");
    assert_eq!(permission.status.code(), Some(3));
    let permission_json: serde_json::Value = serde_json::from_slice(&permission.stdout).unwrap();
    assert_eq!(
        permission_json["hookSpecificOutput"]["decision"]["behavior"],
        "deny"
    );
}

#[test]
fn codex_apply_patch_normalizer_maps_file_hook_payloads() {
    let input = serde_json::json!({
        "hook_event_name": "PreToolUse",
        "tool_name": "apply_patch",
        "tool_input": {
            "command": "*** Begin Patch\n*** Add File: src/new.rs\n+fn main() {}\n*** Update File: src/existing.rs\n-old\n+new\n*** End Patch"
        }
    })
    .to_string();

    let write = run_runtime_with_stdin(
        &[
            "codex-normalize-apply-patch",
            "vibeguard-pre-write-guard.sh",
        ],
        &input,
    );
    assert_eq!(write.status.code(), Some(0));
    let write_lines = String::from_utf8_lossy(&write.stdout);
    let write_json: Vec<serde_json::Value> = write_lines
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(write_json.len(), 1);
    assert_eq!(write_json[0]["tool_name"], "Write");
    assert_eq!(write_json[0]["tool_input"]["file_path"], "src/new.rs");
    assert_eq!(write_json[0]["tool_input"]["content"], "fn main() {}");

    let edit = run_runtime_with_stdin(
        &["codex-normalize-apply-patch", "vibeguard-pre-edit-guard.sh"],
        &input,
    );
    assert_eq!(edit.status.code(), Some(0));
    let edit_lines = String::from_utf8_lossy(&edit.stdout);
    let edit_json: Vec<serde_json::Value> = edit_lines
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(edit_json.len(), 1);
    assert_eq!(edit_json[0]["tool_name"], "Edit");
    assert_eq!(edit_json[0]["tool_input"]["file_path"], "src/existing.rs");
    assert_eq!(edit_json[0]["tool_input"]["new_string"], "new");
    assert_eq!(edit_json[0]["tool_input"]["vibeguard_line_delta"], 0);

    let post_build = run_runtime_with_stdin(
        &[
            "codex-normalize-apply-patch",
            "vibeguard-post-build-check.sh",
        ],
        &input,
    );
    assert_eq!(post_build.status.code(), Some(0));
    let post_build_lines = String::from_utf8_lossy(&post_build.stdout);
    let post_build_json: Vec<serde_json::Value> = post_build_lines
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(post_build_json.len(), 2);
    assert_eq!(post_build_json[0]["tool_name"], "Write");
    assert_eq!(post_build_json[1]["tool_name"], "Edit");

    let moved_delete_input = serde_json::json!({
        "hook_event_name": "PostToolUse",
        "tool_name": "apply_patch",
        "tool_input": {
            "command": "*** Begin Patch\n*** Update File: src/old.rs\n*** Move to: src/current.rs\n-old\n+new\n*** Delete File: src/dead.rs\n-gone\n*** End Patch"
        }
    })
    .to_string();
    let moved_delete = run_runtime_with_stdin(
        &[
            "codex-normalize-apply-patch",
            "vibeguard-post-edit-guard.sh",
        ],
        &moved_delete_input,
    );
    assert_eq!(moved_delete.status.code(), Some(0));
    let moved_delete_lines = String::from_utf8_lossy(&moved_delete.stdout);
    let moved_delete_json: Vec<serde_json::Value> = moved_delete_lines
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(moved_delete_json.len(), 2);
    assert_eq!(moved_delete_json[0]["hook_event_name"], "PostToolUse");
    assert_eq!(
        moved_delete_json[0]["tool_input"]["file_path"],
        "src/current.rs"
    );
    assert_eq!(moved_delete_json[0]["tool_input"]["new_string"], "new");
    assert_eq!(
        moved_delete_json[1]["tool_input"]["file_path"],
        "src/dead.rs"
    );
    assert_eq!(moved_delete_json[1]["tool_input"]["new_string"], "");
    assert_eq!(
        moved_delete_json[1]["tool_input"]["vibeguard_line_delta"],
        -1
    );
}

#[test]
fn codex_hooks_remove_fails_closed_on_manifest_errors() {
    let cases = [
        ("missing-manifest", None),
        ("invalid-manifest-json", Some("{not-json")),
        ("invalid-manifest-schema", Some(r#"{"hooks": {}}"#)),
        (
            "empty-manifest-hooks",
            Some(r#"{"schema_version":1,"profiles":["core"],"hooks":[]}"#),
        ),
    ];

    for (label, manifest) in cases {
        let (repo, hooks_file, before) = codex_setup_fixture(label, manifest);
        let output = run_codex_setup("setup-codex-hooks-remove", &repo, &hooks_file);

        assert_manifest_failure(&output);
        assert_eq!(fs::read(&hooks_file).unwrap(), before);
        fs::remove_dir_all(repo).unwrap();
    }
}

#[test]
fn codex_hooks_reject_nonpositive_manifest_timeout_before_writes() {
    let manifest = valid_codex_manifest(0);
    let (repo, hooks_file, before) =
        codex_setup_fixture("invalid-manifest-timeout", Some(&manifest));
    let output = run_codex_setup("setup-codex-hooks-remove", &repo, &hooks_file);

    assert_manifest_failure(&output);
    assert_eq!(fs::read(&hooks_file).unwrap(), before);
    fs::remove_dir_all(repo).unwrap();
}

#[test]
fn codex_hooks_reject_unsafe_managed_script_before_writes() {
    let mut manifest: serde_json::Value = serde_json::from_str(&valid_codex_manifest(15)).unwrap();
    manifest["hooks"][0]["script"] = serde_json::Value::String("../foo.sh".to_string());
    let manifest = manifest.to_string();
    let (repo, hooks_file, before) = codex_setup_fixture("unsafe-managed-script", Some(&manifest));
    let output = run_codex_setup("setup-codex-hooks-remove", &repo, &hooks_file);

    assert_manifest_failure(&output);
    assert_eq!(fs::read(&hooks_file).unwrap(), before);
    fs::remove_dir_all(repo).unwrap();
}

#[test]
fn codex_setup_validates_manifest_before_missing_hooks_file_short_circuits() {
    for command in [
        "setup-codex-hooks-remove",
        "setup-codex-hooks-prune-stale-unmanaged",
        "setup-codex-hooks-check-stale",
        "setup-codex-hooks-check-timeouts",
    ] {
        let (repo, hooks_file, _) = codex_setup_fixture(command, None);
        fs::remove_file(&hooks_file).unwrap();
        let output = run_codex_setup(command, &repo, &hooks_file);

        assert_manifest_failure(&output);
        assert!(!hooks_file.exists());
        fs::remove_dir_all(repo).unwrap();
    }
}

#[test]
fn codex_hooks_prune_fails_before_output_or_writes_on_invalid_manifest() {
    let (repo, hooks_file, before) =
        codex_setup_fixture("prune-invalid-manifest", Some("{not-json"));
    let output = bin()
        .arg("setup-codex-hooks-prune-stale-unmanaged")
        .arg(&repo)
        .arg(&hooks_file)
        .arg("PreToolUse")
        .output()
        .unwrap();

    assert_manifest_failure(&output);
    assert_eq!(fs::read(&hooks_file).unwrap(), before);
    fs::remove_dir_all(repo).unwrap();
}

#[test]
fn codex_hooks_health_checks_validate_manifest_before_classification() {
    for command in [
        "setup-codex-hooks-check-stale",
        "setup-codex-hooks-check-timeouts",
    ] {
        let (repo, hooks_file, before) = codex_setup_fixture(command, Some(r#"{"hooks": {}}"#));
        let output = run_codex_setup(command, &repo, &hooks_file);

        assert_manifest_failure(&output);
        assert_eq!(fs::read(&hooks_file).unwrap(), before);
        fs::remove_dir_all(repo).unwrap();
    }
}

#[test]
fn codex_hooks_remove_preserves_third_party_hooks_with_valid_manifest() {
    let manifest = valid_codex_manifest(15);
    let (repo, hooks_file, _) = codex_setup_fixture("remove-valid-manifest", Some(&manifest));
    let output = run_codex_setup("setup-codex-hooks-remove", &repo, &hooks_file);

    assert!(output.status.success());
    assert_eq!(String::from_utf8_lossy(&output.stdout), "CHANGED\n");
    let hooks: serde_json::Value = serde_json::from_slice(&fs::read(&hooks_file).unwrap()).unwrap();
    let remaining = hooks
        .pointer("/hooks/PreToolUse/0/hooks")
        .and_then(serde_json::Value::as_array)
        .unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(
        remaining[0]
            .get("command")
            .and_then(serde_json::Value::as_str),
        Some("bash /missing/third-party.sh")
    );
    fs::remove_dir_all(repo).unwrap();
}

#[test]
fn codex_hooks_health_missing_config_is_clean_or_explicit_skip() {
    let manifest = valid_codex_manifest(15);
    let (repo, hooks_file, _) = codex_setup_fixture("health-missing", Some(&manifest));
    fs::remove_file(&hooks_file).unwrap();

    for command in [
        "setup-codex-hooks-check-stale",
        "setup-codex-hooks-check-timeouts",
    ] {
        let output = run_codex_setup(command, &repo, &hooks_file);
        assert!(output.status.success(), "{command}: {output:?}");
        assert!(output.stdout.is_empty(), "{command}");
        assert!(output.stderr.is_empty(), "{command}");
        assert!(!hooks_file.exists(), "{command} created the config");
    }

    let prune = run_codex_setup(
        "setup-codex-hooks-prune-stale-unmanaged",
        &repo,
        &hooks_file,
    );
    assert!(prune.status.success(), "{prune:?}");
    assert_eq!(String::from_utf8_lossy(&prune.stdout), "SKIP\n");
    assert!(prune.stderr.is_empty());
    assert!(!hooks_file.exists());

    let one_arg = bin()
        .arg("setup-codex-hooks-check-stale")
        .arg(&hooks_file)
        .output()
        .unwrap();
    assert!(one_arg.status.success(), "{one_arg:?}");
    assert!(one_arg.stdout.is_empty());
    assert!(one_arg.stderr.is_empty());

    for config in [
        "{}",
        r#"{"hooks":{"PreToolUse":["bad",{}, {"hooks":"bad"}]}}"#,
    ] {
        fs::write(&hooks_file, config).unwrap();
        for command in [
            "setup-codex-hooks-check-stale",
            "setup-codex-hooks-check-timeouts",
        ] {
            let output = run_codex_setup(command, &repo, &hooks_file);
            assert!(output.status.success(), "{command}: {output:?}");
            assert!(output.stdout.is_empty(), "{command}: {output:?}");
            assert!(output.stderr.is_empty(), "{command}: {output:?}");
        }
    }
    fs::remove_dir_all(repo).unwrap();
}

#[test]
fn codex_hooks_health_read_errors_are_visible_and_do_not_write() {
    let manifest = valid_codex_manifest(15);
    let (repo, hooks_file, _) = codex_setup_fixture("health-read-error", Some(&manifest));
    fs::remove_file(&hooks_file).unwrap();
    fs::create_dir(&hooks_file).unwrap();

    for command in [
        "setup-codex-hooks-check-stale",
        "setup-codex-hooks-check-timeouts",
        "setup-codex-hooks-prune-stale-unmanaged",
    ] {
        let output = run_codex_setup(command, &repo, &hooks_file);
        assert!(!output.status.success(), "{command} falsely succeeded");
        assert!(output.stdout.is_empty(), "{command}: {output:?}");
        assert!(!output.stderr.is_empty(), "{command} hid the read error");
        assert!(hooks_file.is_dir(), "{command} replaced the directory");
    }
    fs::remove_dir_all(repo).unwrap();
}

#[test]
fn codex_stale_check_reports_installed_and_unmanaged_missing_targets() {
    let manifest = valid_codex_manifest(15);
    let (repo, hooks_file, _) = codex_setup_fixture("health-stale", Some(&manifest));
    let installed_dir = repo.join(".vibeguard/installed/hooks");
    fs::create_dir_all(&installed_dir).unwrap();
    let existing = repo.join("existing-third-party.sh");
    fs::write(&existing, "#!/bin/sh\n").unwrap();
    let missing_installed = installed_dir.join("missing-installed.sh");
    let missing_blocking = repo.join("missing-blocking.sh");
    let missing_nonblocking = repo.join("missing-nonblocking.js");
    fs::write(
        &hooks_file,
        serde_json::json!({
            "hooks": {
                "PreToolUse": [{
                    "matcher": "Bash",
                    "hooks": [
                        {"command": format!("bash {}", missing_installed.display()), "timeout": 15},
                        {"command": missing_blocking.display().to_string(), "timeout": 15},
                        {"command": format!("bash {}", existing.display()), "timeout": 15},
                        {"command": "echo unresolved", "timeout": 15}
                    ]
                }],
                "PostToolUse": [{
                    "hooks": [{"command": format!("node {}", missing_nonblocking.display()), "timeout": 15}]
                }]
            }
        })
        .to_string(),
    )
    .unwrap();

    let output = run_codex_setup("setup-codex-hooks-check-stale", &repo, &hooks_file);
    assert_eq!(output.status.code(), Some(1), "{output:?}");
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("stale Codex hook command:"), "{stdout}");
    assert!(stdout.contains(missing_installed.to_string_lossy().as_ref()));
    assert!(
        stdout.contains("repair-required unmanaged Codex blocking hook:"),
        "{stdout}"
    );
    assert!(stdout.contains(missing_blocking.to_string_lossy().as_ref()));
    assert!(stdout.contains("stale unmanaged Codex hook:"), "{stdout}");
    assert!(stdout.contains(missing_nonblocking.to_string_lossy().as_ref()));
    assert!(!stdout.contains(existing.to_string_lossy().as_ref()));
    assert!(!stdout.contains("echo unresolved"));
    fs::remove_dir_all(repo).unwrap();
}

#[test]
fn codex_stale_check_resolves_wrapper_script_targets() {
    let manifest = valid_codex_manifest(15);
    let (repo, hooks_file, _) = codex_setup_fixture("health-wrapper", Some(&manifest));
    let vg_dir = repo.join(".vibeguard");
    let installed_dir = vg_dir.join("installed/hooks");
    fs::create_dir_all(&installed_dir).unwrap();
    let wrapper = vg_dir.join("run-hook-codex.sh");
    let present = installed_dir.join("present.sh");
    fs::write(&present, "#!/bin/sh\n").unwrap();
    fs::write(
        &hooks_file,
        serde_json::json!({
            "hooks": {
                "PreToolUse": [{"hooks": [
                    {"command": format!("bash {} present.sh", wrapper.display()), "timeout": 15},
                    {"command": format!("bash {} missing.sh", wrapper.display()), "timeout": 15},
                    {"command": format!("bash {} nested/missing.sh", wrapper.display()), "timeout": 15}
                ]}]
            }
        })
        .to_string(),
    )
    .unwrap();

    let output = run_codex_setup("setup-codex-hooks-check-stale", &repo, &hooks_file);
    assert_eq!(output.status.code(), Some(1), "{output:?}");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains(&installed_dir.join("missing.sh").display().to_string()));
    assert!(!stdout.contains("present.sh"), "{stdout}");
    assert!(
        stdout.contains("repair-required unmanaged Codex blocking hook:"),
        "{stdout}"
    );
    assert!(stdout.contains("nested/missing.sh"), "{stdout}");
    assert!(
        stdout.contains(wrapper.to_string_lossy().as_ref()),
        "{stdout}"
    );
    fs::remove_dir_all(repo).unwrap();
}

#[test]
fn codex_prune_removes_only_selected_missing_unmanaged_hooks() {
    let manifest = valid_codex_manifest(15);
    let (repo, hooks_file, _) = codex_setup_fixture("health-prune", Some(&manifest));
    let existing = repo.join("existing.sh");
    let stale = repo.join("stale.sh");
    let unselected = repo.join("unselected.sh");
    fs::write(&existing, "#!/bin/sh\n").unwrap();
    let managed = repo.join("vibeguard-pre-bash-guard.sh");
    let original = serde_json::json!({
        "hooks": {
            "PreToolUse": [
                {"matcher": "Bash", "hooks": [
                    {"command": format!("bash {}", stale.display())},
                    {"command": format!("bash {}", existing.display())},
                    {"command": format!("bash {}", managed.display())},
                    {"command": "echo unresolved"}
                ]},
                "malformed-entry",
                {"matcher": "Read"}
            ],
            "PostToolUse": [{"hooks": [{"command": format!("bash {}", unselected.display())}]}],
            "MalformedEvent": {"hooks": []}
        }
    });
    fs::write(&hooks_file, original.to_string()).unwrap();

    let output = bin()
        .arg("setup-codex-hooks-prune-stale-unmanaged")
        .arg(&repo)
        .arg(&hooks_file)
        .arg("PreToolUse")
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("removed stale unmanaged Codex hook:"),
        "{stdout}"
    );
    assert!(stdout.ends_with("CHANGED\n"), "{stdout}");

    let updated: serde_json::Value =
        serde_json::from_slice(&fs::read(&hooks_file).unwrap()).unwrap();
    let text = updated.to_string();
    assert!(!text.contains(stale.to_string_lossy().as_ref()));
    assert!(text.contains(existing.to_string_lossy().as_ref()));
    assert!(text.contains(managed.to_string_lossy().as_ref()));
    assert!(text.contains("echo unresolved"));
    assert!(text.contains(unselected.to_string_lossy().as_ref()));
    assert!(text.contains("malformed-entry"));
    assert!(updated["hooks"].get("MalformedEvent").is_none());
    fs::remove_dir_all(repo).unwrap();
}

#[test]
fn codex_timeout_check_distinguishes_managed_and_unmanaged_repairs() {
    let manifest = valid_codex_manifest(15);
    let (repo, hooks_file, _) = codex_setup_fixture("health-timeout", Some(&manifest));
    let managed = repo.join("vibeguard-pre-bash-guard.sh");
    let unmanaged = repo.join("third-party.sh");
    fs::write(
        &hooks_file,
        serde_json::json!({
            "hooks": {
                "PreToolUse": [{"matcher": "", "hooks": [
                    {"command": format!("bash {}", managed.display())},
                    {"command": format!("bash {}", unmanaged.display()), "timeout": 0},
                    {"command": "bash /ignored-positive.sh", "timeout": 1},
                    {"command": ""},
                    "malformed"
                ]}],
                "MalformedEvent": "not-an-array"
            }
        })
        .to_string(),
    )
    .unwrap();

    let output = run_codex_setup("setup-codex-hooks-check-timeouts", &repo, &hooks_file);
    assert_eq!(output.status.code(), Some(1), "{output:?}");
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("managed Codex hook without timeout:"),
        "{stdout}"
    );
    assert!(stdout.contains("repair=bash setup.sh --yes"), "{stdout}");
    assert!(
        stdout.contains("unmanaged Codex hook without timeout:"),
        "{stdout}"
    );
    assert!(
        stdout.contains("repair=add timeout or consult hook owner"),
        "{stdout}"
    );
    assert_eq!(stdout.matches("Codex hook without timeout:").count(), 2);
    assert!(stdout.contains("matcher=<none>"));
    fs::remove_dir_all(repo).unwrap();
}

#[test]
fn codex_prune_handles_empty_malformed_kept_and_fully_removed_containers() {
    let manifest = valid_codex_manifest(15);
    let (repo, hooks_file, _) = codex_setup_fixture("health-prune-containers", Some(&manifest));

    for data in [
        serde_json::json!({}),
        serde_json::json!({"hooks": {"PreToolUse": {"hooks": []}}}),
        serde_json::json!({"hooks": {"PreToolUse": [{"hooks": [
            {"command": "echo unresolved"}
        ]}]}}),
    ] {
        fs::write(&hooks_file, data.to_string()).unwrap();
        let output = run_codex_setup(
            "setup-codex-hooks-prune-stale-unmanaged",
            &repo,
            &hooks_file,
        );
        assert!(output.status.success(), "{output:?}");
        assert_eq!(String::from_utf8_lossy(&output.stdout), "SKIP\n");
        assert!(output.stderr.is_empty());
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&fs::read(&hooks_file).unwrap()).unwrap(),
            data
        );
    }

    let stale = repo.join("only-stale.sh");
    fs::write(
        &hooks_file,
        serde_json::json!({"hooks": {"PreToolUse": [{"hooks": [
            {"command": format!("bash {}", stale.display())}
        ]}]}})
        .to_string(),
    )
    .unwrap();
    let output = run_codex_setup(
        "setup-codex-hooks-prune-stale-unmanaged",
        &repo,
        &hooks_file,
    );
    assert!(output.status.success(), "{output:?}");
    assert!(
        String::from_utf8_lossy(&output.stdout).ends_with("CHANGED\n"),
        "{output:?}"
    );
    assert!(output.stderr.is_empty());
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&fs::read(&hooks_file).unwrap()).unwrap(),
        serde_json::json!({})
    );
    fs::remove_dir_all(repo).unwrap();
}
