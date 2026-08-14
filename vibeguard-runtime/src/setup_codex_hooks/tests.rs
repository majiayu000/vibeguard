use super::*;

fn repo_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..")
}

#[test]
fn manifest_rejects_requested_canonical_script_mismatch() {
    let manifest_path = repo_dir().join("hooks/manifest.json");
    let mut manifest: Value = serde_json::from_str(
        &std::fs::read_to_string(manifest_path).expect("read repository manifest"),
    )
    .expect("parse repository manifest");
    let hook = manifest["hooks"]
        .as_array_mut()
        .and_then(|hooks| {
            hooks
                .iter_mut()
                .find(|hook| hook.pointer("/codex/enabled").and_then(Value::as_bool) == Some(true))
        })
        .expect("enabled Codex hook");
    hook["codex"]["script"] = Value::String("vibeguard-mismatched.sh".to_string());

    let error = match codex_manifest_value(&manifest) {
        Ok(_) => panic!("requested/canonical mismatch must fail"),
        Err(error) => error,
    };
    assert!(error.to_string().contains("for canonical script"));
}

#[test]
fn prune_current_managed_keeps_third_party_hooks_in_mixed_entry() {
    let repo_dir = repo_dir();
    let mut data = json!({
        "hooks": {
            "PreToolUse": [
                {
                    "matcher": "Bash",
                    "hooks": [
                        {
                            "type": "command",
                            "command": "bash /tmp/run-hook-codex.sh vibeguard-pre-bash-guard.sh"
                        },
                        {
                            "type": "command",
                            "command": "bash /tmp/third-party.sh"
                        }
                    ]
                }
            ]
        }
    });

    let managed_scripts = match codex_managed_scripts(&repo_dir) {
        Ok(scripts) => scripts,
        Err(error) => panic!("repository manifest must be valid: {error}"),
    };
    codex_prune_managed(&mut data, &managed_scripts);

    let hooks = data
        .pointer("/hooks/PreToolUse/0/hooks")
        .and_then(Value::as_array);
    assert_eq!(hooks.map(Vec::len), Some(1));
    assert_eq!(
        hooks
            .and_then(|items| items.first())
            .and_then(|hook| hook.get("command"))
            .and_then(Value::as_str),
        Some("bash /tmp/third-party.sh")
    );
}

#[test]
fn built_entries_preserve_matcher_and_timeout() {
    let spec = CodexSpec {
        event: "Stop".to_string(),
        matcher: None,
        script: "vibeguard-stop-guard.sh".to_string(),
        timeout: Some(15),
    };

    let entry = codex_build_entry("/tmp/run-hook-codex.sh", &spec, "full");
    assert_eq!(entry.get("matcher"), None);
    let hook = entry
        .get("hooks")
        .and_then(Value::as_array)
        .and_then(|items| items.first());
    assert_eq!(
        hook.and_then(|value| value.get("command"))
            .and_then(Value::as_str),
        Some(
            "env VIBEGUARD_PROFILE=\"${VIBEGUARD_PROFILE:-full}\" bash /tmp/run-hook-codex.sh vibeguard-stop-guard.sh"
        )
    );
    assert_eq!(
        hook.and_then(|value| value.get("timeout"))
            .and_then(Value::as_i64),
        Some(15)
    );
}

#[test]
fn managed_entry_check_requires_expected_timeout() {
    let repo_dir = repo_dir();
    let managed_scripts = match codex_managed_scripts(&repo_dir) {
        Ok(scripts) => scripts,
        Err(error) => panic!("repository manifest must be valid: {error}"),
    };
    let command = "bash /tmp/run-hook-codex.sh vibeguard-stop-guard.sh";
    let entries = vec![json!({
        "hooks": [
            {
                "type": "command",
                "command": command,
                "timeout": 99
            }
        ]
    })];

    assert!(!codex_has_entry(
        &entries,
        &managed_scripts,
        command,
        None,
        Some(15)
    ));
    assert!(codex_has_entry(
        &entries,
        &managed_scripts,
        command,
        None,
        Some(99)
    ));
}
