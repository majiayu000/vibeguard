mod common;

use common::{assert_output, bin, path_text, unique_temp_dir, write_json};
use serde_json::json;
use std::fs;

/// Preflight requires an active quarantine record to name durable artifacts
/// that exist and describe the record, so fixtures must materialize them.
fn materialize_quarantine_artifacts(
    dest: &std::path::Path,
    quarantine: &std::path::Path,
    transaction: &std::path::Path,
    record: &serde_json::Value,
    phase: &str,
) {
    fs::create_dir_all(quarantine).expect("quarantine directory should be created");
    let mut value = record.clone();
    let object = value.as_object_mut().expect("record should be an object");
    object.insert("dest".into(), json!(path_text(dest)));
    object.insert("phase".into(), json!(phase));
    write_json(transaction, &value);
}

#[test]
fn quarantine_count_rejects_invalid_arity() {
    let output = bin()
        .arg("setup-state-quarantine-count")
        .output()
        .expect("quarantine count command should run");
    assert_output(
        &output,
        1,
        "",
        "vibeguard-runtime error: Usage: vibeguard-runtime setup-state-quarantine-count <state-file> [released-inventory-state-file]\n",
    );
}

#[test]
fn quarantine_count_reports_missing_empty_and_active_inventory() {
    let root = unique_temp_dir("quarantine-count");
    let state = root.join("state.json");
    let missing = bin()
        .args(["setup-state-quarantine-count", &path_text(&state)])
        .output()
        .expect("missing state command should run");
    assert_output(&missing, 0, "0\n", "");

    write_json(&state, &json!({"version": 1, "files": {}}));
    let empty = bin()
        .args(["setup-state-quarantine-count", &path_text(&state)])
        .output()
        .expect("empty state command should run");
    assert_output(&empty, 0, "0\n", "");

    let dest = root.join("skills/plan-flow");
    let parent = dest.parent().expect("destination should have parent");
    let quarantine = parent.join(".plan-flow.vibeguard-quarantine.nonce");
    let transaction = parent.join(".plan-flow.vibeguard-transaction.nonce.json");
    let record = json!({
        "version": 1,
        "quarantine": path_text(&quarantine),
        "transaction": path_text(&transaction),
        "source_prefix": "skills/plan-flow",
        "tracked_digest": format!("sha256:{}", "a".repeat(64)),
        "install_state_generation": 1,
        "nonce": "nonce"
    });
    materialize_quarantine_artifacts(&dest, &quarantine, &transaction, &record, "committed");
    write_json(
        &state,
        &json!({
            "version": 1,
            "files": {},
            "disabled_skill_quarantines": { path_text(&dest): record }
        }),
    );
    let active = bin()
        .args(["setup-state-quarantine-count", &path_text(&state)])
        .output()
        .expect("active state command should run");
    assert_output(&active, 0, "1\n", "");
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn quarantine_count_rejects_invalid_install_state_structure() {
    let root = unique_temp_dir("quarantine-count-invalid-state");
    let state = root.join("state.json");
    write_json(&state, &json!({"version": 1, "files": []}));

    let output = bin()
        .args(["setup-state-quarantine-count", &path_text(&state)])
        .output()
        .expect("invalid state command should run");
    assert_eq!(output.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("install-state files must be an object")
    );
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn drift_rejects_quarantine_locators_that_do_not_match_nonce() {
    let root = unique_temp_dir("quarantine-drift-invalid-locator");
    let state = root.join("state.json");
    let dest = root.join("skills/plan-flow");
    let parent = dest.parent().expect("destination should have parent");
    write_json(
        &state,
        &json!({
            "version": 1,
            "files": {},
            "disabled_skill_quarantines": {
                path_text(&dest): {
                    "version": 1,
                    "quarantine": path_text(&parent.join(".plan-flow.vibeguard-quarantine.wrong")),
                    "transaction": path_text(&parent.join(".plan-flow.vibeguard-transaction.wrong.json")),
                    "source_prefix": "skills/plan-flow",
                    "tracked_digest": format!("sha256:{}", "a".repeat(64)),
                    "install_state_generation": 1,
                    "nonce": "expected"
                }
            }
        }),
    );

    let output = bin()
        .args(["setup-state-check-drift", &path_text(&state)])
        .output()
        .expect("invalid locator drift command should run");
    assert_eq!(output.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("quarantine locator does not match its nonce")
    );
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn drift_checks_active_quarantine_bytes_instead_of_public_path() {
    let root = unique_temp_dir("quarantine-drift");
    let state = root.join("state.json");
    let dest = root.join("skills/plan-flow");
    let quarantine = root.join("skills/.plan-flow.vibeguard-quarantine.nonce");
    let transaction = root.join("skills/.plan-flow.vibeguard-transaction.nonce.json");
    fs::create_dir_all(&quarantine).expect("quarantine should be created");
    fs::write(quarantine.join("SKILL.md"), "hello").expect("quarantined skill should be written");
    let record = json!({
        "version": 1,
        "quarantine": path_text(&quarantine),
        "transaction": path_text(&transaction),
        "source_prefix": "skills/plan-flow",
        "tracked_digest": format!("sha256:{}", "a".repeat(64)),
        "install_state_generation": 1,
        "nonce": "nonce"
    });
    materialize_quarantine_artifacts(&dest, &quarantine, &transaction, &record, "committed");
    write_json(
        &state,
        &json!({
            "version": 1,
            "files": {
                path_text(&dest.join("SKILL.md")): {
                    "source": "skills/plan-flow/SKILL.md",
                    "type": "copy",
                    "checksum": "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
                }
            },
            "disabled_skill_quarantines": { path_text(&dest): record }
        }),
    );
    let output = bin()
        .args(["setup-state-check-drift", &path_text(&state)])
        .output()
        .expect("drift command should run");
    assert_output(
        &output,
        0,
        "---\nTotal tracked: 1, Missing: 0, Drifted: 0\nSTATUS: CLEAN\n",
        "",
    );
    fs::write(quarantine.join("SKILL.md"), "changed").expect("quarantined skill should be mutated");
    let drifted = bin()
        .args(["setup-state-check-drift", &path_text(&state)])
        .output()
        .expect("drift command should rerun");
    assert_output(
        &drifted,
        0,
        &format!(
            "DRIFT: {} (checksum mismatch)\n---\nTotal tracked: 1, Missing: 0, Drifted: 1\nSTATUS: DRIFT (1 drifted, 0 missing)\n",
            dest.join("SKILL.md").display()
        ),
        "",
    );
    fs::remove_file(&transaction).expect("transaction should be removed");
    let missing_transaction = bin()
        .args(["setup-state-check-drift", &path_text(&state)])
        .output()
        .expect("drift with missing transaction should run");
    assert_eq!(missing_transaction.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&missing_transaction.stderr)
            .contains("active quarantine transaction cannot be proven")
    );
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn init_retry_preserves_incomplete_quarantine_locator_and_inventory() {
    let root = unique_temp_dir("quarantine-init-retry");
    let state = root.join("state.json");
    let dest = root.join("skills/plan-flow");
    let quarantine = root.join("skills/.plan-flow.vibeguard-quarantine.nonce");
    let transaction = root.join("skills/.plan-flow.vibeguard-transaction.nonce.json");
    let tracked = path_text(&dest.join("SKILL.md"));
    let record = json!({
        "version": 1,
        "quarantine": path_text(&quarantine),
        "transaction": path_text(&transaction),
        "source_prefix": "skills/plan-flow",
        "tracked_digest": format!("sha256:{}", "a".repeat(64)),
        "install_state_generation": 5,
        "nonce": "nonce"
    });
    materialize_quarantine_artifacts(&dest, &quarantine, &transaction, &record, "committed");
    write_json(
        &state,
        &json!({
            "version": 1,
            "generation": 5,
            "complete": false,
            "files": {
                tracked.clone(): {
                    "source": "skills/plan-flow/SKILL.md",
                    "type": "copy",
                    "checksum": "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
                }
            },
            "disabled_skill_quarantines": { path_text(&dest): record }
        }),
    );
    let output = bin()
        .args(["setup-state-init", &path_text(&state), "core", "", "5"])
        .env("HOME", root.join("home"))
        .output()
        .expect("init retry should run");
    assert_output(&output, 0, "", "");
    let retained: serde_json::Value =
        serde_json::from_slice(&fs::read(&state).expect("state should be readable"))
            .expect("state should remain JSON");
    assert!(
        retained["disabled_skill_quarantines"]
            .get(path_text(&dest))
            .is_some()
    );
    assert!(retained["files"].get(tracked).is_some());
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn init_retry_preserves_verifiable_incomplete_disabled_skill_inventory() {
    let root = unique_temp_dir("quarantine-init-new-opt-out");
    let state = root.join("state.json");
    let home = root.join("home");
    let skill = home.join(".codex/skills/plan-flow/SKILL.md");
    fs::create_dir_all(skill.parent().expect("skill should have parent"))
        .expect("skill parent should be created");
    fs::write(&skill, "hello").expect("managed skill should be written");
    let modified = skill
        .parent()
        .expect("skill should have parent")
        .join("USER.md");
    fs::write(&modified, "changed").expect("modified skill file should be written");
    let other = home.join(".codex/skills/fixflow/SKILL.md");
    fs::create_dir_all(other.parent().expect("other skill should have parent"))
        .expect("other skill parent should be created");
    fs::write(&other, "hello").expect("other skill should be written");
    let tracked = path_text(&skill);
    let modified_tracked = path_text(&modified);
    let other_tracked = path_text(&other);
    let unsupported_tracked = path_text(
        &skill
            .parent()
            .expect("skill should have parent")
            .join("LINK.md"),
    );
    write_json(
        &state,
        &json!({
            "version": 1,
            "generation": 5,
            "complete": false,
            "files": {
                tracked.clone(): {
                    "source": "workflows/plan-flow/SKILL.md",
                    "type": "copy",
                    "checksum": "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
                },
                modified_tracked.clone(): {
                    "source": "workflows/plan-flow/USER.md",
                    "type": "copy",
                    "checksum": "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
                },
                other_tracked.clone(): {
                    "source": "workflows/fixflow/SKILL.md",
                    "type": "copy",
                    "checksum": "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
                },
                unsupported_tracked.clone(): {
                    "source": "workflows/plan-flow/LINK.md",
                    "type": "symlink"
                }
            }
        }),
    );

    let output = bin()
        .args([
            "setup-state-init",
            &path_text(&state),
            "core",
            "",
            "5",
            "plan-flow",
        ])
        .env("HOME", &home)
        .output()
        .expect("new opt-out init retry should run");
    assert_output(&output, 0, "", "");
    let retained: serde_json::Value =
        serde_json::from_slice(&fs::read(&state).expect("state should be readable"))
            .expect("state should remain JSON");
    assert!(retained["files"].get(tracked).is_some());
    assert!(retained["files"].get(modified_tracked).is_none());
    assert!(retained["files"].get(other_tracked).is_none());
    assert!(retained["files"].get(unsupported_tracked).is_none());
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn init_retry_preserves_inventory_after_an_intent_quarantine_rename() {
    let root = unique_temp_dir("quarantine-init-intent-retry");
    let home = root.join("home");
    let state = root.join("state.json");
    let dest = home.join(".codex/skills/plan-flow");
    let tracked = dest.join("SKILL.md");
    fs::create_dir_all(&dest).expect("public skill should be created");
    fs::write(&tracked, "hello").expect("managed skill should be written");
    write_json(
        &state,
        &json!({
            "version": 1,
            "generation": 5,
            "complete": false,
            "files": {
                path_text(&tracked): {
                    "source": "workflows/plan-flow/SKILL.md",
                    "type": "copy",
                    "checksum": "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
                }
            }
        }),
    );
    let quarantine = dest
        .parent()
        .unwrap()
        .join(".plan-flow.vibeguard-quarantine.intent");
    let transaction = dest
        .parent()
        .unwrap()
        .join(".plan-flow.vibeguard-transaction.intent.json");
    fs::rename(&dest, &quarantine).expect("public skill should be quarantined");
    write_json(
        &transaction,
        &json!({
            "version": 1,
            "phase": "intent",
            "dest": path_text(&dest),
            "quarantine": path_text(&quarantine),
            "transaction": path_text(&transaction),
            "source_prefix": "workflows/plan-flow",
            "tracked_digest": format!("sha256:{}", "a".repeat(64)),
            "install_state_generation": 5,
            "nonce": "intent"
        }),
    );

    let output = bin()
        .args([
            "setup-state-init",
            &path_text(&state),
            "core",
            "",
            "5",
            "plan-flow",
        ])
        .env("HOME", &home)
        .output()
        .expect("intent retry init should run");
    assert_output(&output, 0, "", "");
    let retained: serde_json::Value =
        serde_json::from_slice(&fs::read(&state).expect("state should be readable"))
            .expect("state should remain JSON");
    assert!(retained["files"].get(path_text(&tracked)).is_some());
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn init_carries_active_quarantine_for_a_retired_manifest_skill() {
    let root = unique_temp_dir("quarantine-init-retired-skill");
    let state = root.join("state.json");
    let dest = root.join("skills/plan-flow");
    let quarantine = root.join("skills/.plan-flow.vibeguard-quarantine.nonce");
    let transaction = root.join("skills/.plan-flow.vibeguard-transaction.nonce.json");
    let tracked = path_text(&dest.join("SKILL.md"));
    let record = json!({
        "version": 1,
        "quarantine": path_text(&quarantine),
        "transaction": path_text(&transaction),
        "source_prefix": "skills/plan-flow",
        "tracked_digest": format!("sha256:{}", "a".repeat(64)),
        "install_state_generation": 5,
        "nonce": "nonce"
    });
    materialize_quarantine_artifacts(&dest, &quarantine, &transaction, &record, "committed");
    // A complete previous generation: the earlier carry rule dropped its
    // quarantine records entirely.
    write_json(
        &state,
        &json!({
            "version": 1,
            "generation": 5,
            "complete": true,
            "files": {
                tracked.clone(): {
                    "source": "skills/plan-flow/SKILL.md",
                    "type": "copy",
                    "checksum": "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
                }
            },
            "disabled_skill_quarantines": { path_text(&dest): record }
        }),
    );

    // Generation 6 no longer lists plan-flow, so the install loop never visits
    // the name and nothing else republishes the locator.
    let output = bin()
        .args(["setup-state-init", &path_text(&state), "core", "", "6"])
        .env("HOME", root.join("home"))
        .output()
        .expect("next generation init should run");
    assert_output(&output, 0, "", "");

    let carried: serde_json::Value =
        serde_json::from_slice(&fs::read(&state).expect("state should be readable"))
            .expect("state should remain JSON");
    assert!(
        carried["disabled_skill_quarantines"]
            .get(path_text(&dest))
            .is_some(),
        "retired manifest skill must keep ownership of its retained tree"
    );
    assert!(
        carried["files"].get(tracked).is_some(),
        "carried quarantine must keep its tracked file inventory"
    );
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn preflight_rejects_an_active_quarantine_whose_artifacts_are_gone() {
    let root = unique_temp_dir("quarantine-preflight-missing-artifacts");
    let state = root.join("state.json");
    let dest = root.join("skills/plan-flow");
    let quarantine = root.join("skills/.plan-flow.vibeguard-quarantine.nonce");
    let transaction = root.join("skills/.plan-flow.vibeguard-transaction.nonce.json");
    let record = json!({
        "version": 1,
        "quarantine": path_text(&quarantine),
        "transaction": path_text(&transaction),
        "source_prefix": "skills/plan-flow",
        "tracked_digest": format!("sha256:{}", "a".repeat(64)),
        "install_state_generation": 1,
        "nonce": "nonce"
    });
    materialize_quarantine_artifacts(&dest, &quarantine, &transaction, &record, "committed");
    write_json(
        &state,
        &json!({
            "version": 1,
            "files": {},
            "disabled_skill_quarantines": { path_text(&dest): record }
        }),
    );
    // Locator strings stay correct; only the durable artifact disappears.
    fs::remove_dir_all(&quarantine).expect("quarantine directory should be removed");

    let output = bin()
        .args(["setup-state-quarantine-count", &path_text(&state)])
        .output()
        .expect("preflight command should run");
    assert_eq!(output.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("active quarantine directory cannot be proven"),
        "preflight must name the unprovable artifact: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn preflight_rejects_public_replacements_terminal_phases_and_schema_drift() {
    let root = unique_temp_dir("quarantine-preflight-exact-transaction");
    let state = root.join("state.json");
    let dest = root.join("skills/plan-flow");
    let quarantine = root.join("skills/.plan-flow.vibeguard-quarantine.nonce");
    let transaction = root.join("skills/.plan-flow.vibeguard-transaction.nonce.json");
    let record = json!({
        "version": 1,
        "quarantine": path_text(&quarantine),
        "transaction": path_text(&transaction),
        "source_prefix": "skills/plan-flow",
        "tracked_digest": format!("sha256:{}", "a".repeat(64)),
        "install_state_generation": 1,
        "nonce": "nonce"
    });
    materialize_quarantine_artifacts(&dest, &quarantine, &transaction, &record, "committed");
    write_json(
        &state,
        &json!({
            "version": 1,
            "files": {},
            "disabled_skill_quarantines": { path_text(&dest): record }
        }),
    );

    fs::create_dir_all(&dest).expect("public replacement should be created");
    fs::write(dest.join("USER.md"), "user").expect("public replacement should be written");
    let public = bin()
        .args(["setup-state-quarantine-count", &path_text(&state)])
        .output()
        .expect("public replacement preflight should run");
    assert_eq!(public.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&public.stderr).contains("unexpectedly exists"));
    fs::remove_dir_all(&dest).expect("public replacement should be removed");

    for phase in ["restored", "unknown"] {
        materialize_quarantine_artifacts(&dest, &quarantine, &transaction, &record, phase);
        let output = bin()
            .args(["setup-state-quarantine-count", &path_text(&state)])
            .output()
            .expect("terminal phase preflight should run");
        assert_eq!(output.status.code(), Some(1));
        assert!(String::from_utf8_lossy(&output.stderr).contains("phase is not recoverable"));
    }

    materialize_quarantine_artifacts(&dest, &quarantine, &transaction, &record, "committed");
    let mut value: serde_json::Value =
        serde_json::from_slice(&fs::read(&transaction).expect("transaction should read"))
            .expect("transaction should parse");
    value["unexpected"] = json!(true);
    write_json(&transaction, &value);
    let schema = bin()
        .args(["setup-state-quarantine-count", &path_text(&state)])
        .output()
        .expect("schema preflight should run");
    assert_eq!(schema.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&schema.stderr).contains("unknown or missing fields"));

    materialize_quarantine_artifacts(&dest, &quarantine, &transaction, &record, "released");
    fs::create_dir_all(&dest).expect("released public tree should be created");
    fs::write(dest.join("SKILL.md"), "managed\n").expect("released public file should exist");
    let mut released_state: serde_json::Value =
        serde_json::from_slice(&fs::read(&state).expect("state should read"))
            .expect("state should parse");
    released_state["files"][path_text(&dest.join("SKILL.md"))] = json!({
        "source": "skills-v2/plan-flow/SKILL.md",
        "type": "copy",
        "checksum": "sha256:5b4bc29f140e30c01417d810e700ecc54a84a0107566d84215b42e5742ef8d96"
    });
    released_state["files"][path_text(&dest.join("REMOVED.md"))] = json!({
        "source": "skills/plan-flow/REMOVED.md",
        "type": "copy",
        "checksum": "sha256:5b4bc29f140e30c01417d810e700ecc54a84a0107566d84215b42e5742ef8d96"
    });
    write_json(&state, &released_state);
    let released = bin()
        .args(["setup-state-quarantine-count", &path_text(&state)])
        .output()
        .expect("released phase preflight should run");
    assert_output(&released, 0, "1\n", "");
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn complete_snapshot_merge_preserves_current_inventory_and_previous_only_ownership() {
    let root = unique_temp_dir("quarantine-complete-snapshot-merge");
    let snapshot = root.join("install-state.previous.tmp");
    let carry = root.join("install-state.previous.json");
    let current_owned = root.join("skills/current/SKILL.md");
    let dest = root.join("skills/retired");
    let quarantine = root.join("skills/.retired.vibeguard-quarantine.nonce");
    let transaction = root.join("skills/.retired.vibeguard-transaction.nonce.json");
    fs::create_dir_all(current_owned.parent().unwrap()).unwrap();
    fs::write(&current_owned, "hello").unwrap();
    fs::create_dir_all(&quarantine).unwrap();
    fs::write(quarantine.join("SKILL.md"), "hello").unwrap();
    let record = json!({
        "version": 1,
        "quarantine": path_text(&quarantine),
        "transaction": path_text(&transaction),
        "source_prefix": "skills/retired",
        "tracked_digest": format!("sha256:{}", "a".repeat(64)),
        "install_state_generation": 4,
        "nonce": "nonce"
    });
    materialize_quarantine_artifacts(&dest, &quarantine, &transaction, &record, "committed");
    write_json(
        &snapshot,
        &json!({
            "version": 1, "generation": 5, "complete": true,
            "files": { path_text(&current_owned): {
                "source": "skills/current/SKILL.md", "type": "copy",
                "checksum": "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
            }}
        }),
    );
    write_json(
        &carry,
        &json!({
            "version": 1, "generation": 4, "complete": true,
            "files": { path_text(&dest.join("SKILL.md")): {
                "source": "skills/retired/SKILL.md", "type": "copy",
                "checksum": "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
            }},
            "disabled_skill_quarantines": { path_text(&dest): record }
        }),
    );

    let merged = bin()
        .args([
            "setup-state-init",
            &path_text(&snapshot),
            "",
            "",
            "5",
            "",
            &path_text(&carry),
            "complete-snapshot",
        ])
        .output()
        .expect("complete snapshot merge should run");
    assert_output(&merged, 0, "", "");
    let value: serde_json::Value = serde_json::from_slice(&fs::read(&snapshot).unwrap()).unwrap();
    assert_eq!(value["generation"], 5);
    assert_eq!(value["complete"], true);
    assert!(value["files"].get(path_text(&current_owned)).is_some());
    assert!(
        value["files"]
            .get(path_text(&dest.join("SKILL.md")))
            .is_some()
    );
    assert!(
        value["disabled_skill_quarantines"]
            .get(path_text(&dest))
            .is_some()
    );
    let mut incomplete = value;
    incomplete["complete"] = json!(false);
    write_json(&snapshot, &incomplete);
    let before = fs::read(&snapshot).unwrap();
    let rejected = bin()
        .args([
            "setup-state-init",
            &path_text(&snapshot),
            "",
            "",
            "5",
            "",
            &path_text(&carry),
            "complete-snapshot",
        ])
        .output()
        .expect("incomplete snapshot merge should run");
    assert_eq!(rejected.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&rejected.stderr).contains("must be complete"));
    assert_eq!(fs::read(&snapshot).unwrap(), before);
    fs::remove_dir_all(root).expect("temp root should be removed");
}
