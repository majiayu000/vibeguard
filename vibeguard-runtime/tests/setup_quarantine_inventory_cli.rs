mod common;

use common::{assert_output, bin, path_text, unique_temp_dir, write_json};
use serde_json::json;
use std::fs;

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
        "vibeguard-runtime error: Usage: vibeguard-runtime setup-state-quarantine-count <state-file>\n",
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
    write_json(
        &state,
        &json!({
            "version": 1,
            "files": {},
            "disabled_skill_quarantines": {
                path_text(&dest): {
                    "version": 1,
                    "quarantine": path_text(&quarantine),
                    "transaction": path_text(&transaction),
                    "source_prefix": "skills/plan-flow",
                    "tracked_digest": format!("sha256:{}", "a".repeat(64)),
                    "install_state_generation": 1,
                    "nonce": "nonce"
                }
            }
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
            "disabled_skill_quarantines": {
                path_text(&dest): {
                    "version": 1,
                    "quarantine": path_text(&quarantine),
                    "transaction": path_text(&transaction),
                    "source_prefix": "skills/plan-flow",
                    "tracked_digest": format!("sha256:{}", "a".repeat(64)),
                    "install_state_generation": 1,
                    "nonce": "nonce"
                }
            }
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
            "disabled_skill_quarantines": {
                path_text(&dest): {
                    "version": 1,
                    "quarantine": path_text(&quarantine),
                    "transaction": path_text(&transaction),
                    "source_prefix": "skills/plan-flow",
                    "tracked_digest": format!("sha256:{}", "a".repeat(64)),
                    "install_state_generation": 5,
                    "nonce": "nonce"
                }
            }
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
