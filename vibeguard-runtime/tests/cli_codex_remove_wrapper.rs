mod common;

use common::{bin, unique_temp_dir};
use std::fs;
use std::path::PathBuf;

fn remove_wrapper_fixture() -> (PathBuf, PathBuf) {
    let repo = unique_temp_dir("codex-remove-wrapper");
    let hooks_dir = repo.join("hooks");
    fs::create_dir_all(&hooks_dir).unwrap();
    fs::write(
        hooks_dir.join("manifest.json"),
        serde_json::json!({
            "schema_version": 1,
            "profiles": ["core"],
            "hooks": [{
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
                    "timeout": 15
                }
            }]
        })
        .to_string(),
    )
    .unwrap();
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
            "command": "bash /tmp/custom-wrapper.sh vibeguard-pre-bash-guard.sh",
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
    (repo, hooks_file)
}

#[test]
fn codex_hooks_remove_requires_configured_wrapper_for_custom_installs() {
    let (repo, hooks_file) = remove_wrapper_fixture();

    let without_wrapper = bin()
        .arg("setup-codex-hooks-remove")
        .arg(&repo)
        .arg(&hooks_file)
        .output()
        .unwrap();
    assert!(without_wrapper.status.success());
    assert_eq!(
        String::from_utf8_lossy(&without_wrapper.stdout),
        "SKIP\n",
        "custom wrapper installs stay unrecognized without the configured wrapper"
    );
    let before = fs::read_to_string(&hooks_file).unwrap();
    assert!(before.contains("custom-wrapper.sh vibeguard-pre-bash-guard.sh"));

    let with_wrapper = bin()
        .arg("setup-codex-hooks-remove")
        .arg(&repo)
        .arg(&hooks_file)
        .arg("/tmp/custom-wrapper.sh")
        .output()
        .unwrap();
    assert!(with_wrapper.status.success());
    assert_eq!(String::from_utf8_lossy(&with_wrapper.stdout), "CHANGED\n");
    let after: serde_json::Value =
        serde_json::from_slice(&fs::read(&hooks_file).unwrap()).unwrap();
    let remaining = after
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
