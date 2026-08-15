mod common;

use common::{assert_output, bin, path_text, read_json, unique_temp_dir, write_json};
use serde_json::{Value, json};
use std::fs;
use std::path::Path;
use std::process::Command;

const HELLO_SHA: &str = "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
const OLD_SHA: &str = "sha256:cba06b5736faf67e54b07b561eae94395e774c517a7d910a54369e1263ccfbd4";
const NEW_SHA: &str = "sha256:11507a0e2f5e69d5dfa40a62a1bd7b6ee57e6bcd85c67c9b8431b36fff21c437";

fn tracked_digest(dest: &Path, source: &str, checksum: &str) -> String {
    let inventory = json!({
        path_text(&dest.join("SKILL.md")): {
            "source": source,
            "type": "copy",
            "checksum": checksum
        }
    });
    let canonical = serde_json::to_string(inventory.as_object().unwrap()).unwrap();
    let output = Command::new("python3")
        .args([
            "-c",
            "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())",
            &canonical,
        ])
        .output()
        .expect("Python must compute the canonical inventory digest");
    assert!(output.status.success());
    format!("sha256:{}", String::from_utf8_lossy(&output.stdout).trim())
}

fn record_and_transaction(
    dest: &Path,
    quarantine: &Path,
    transaction: &Path,
    source: &str,
    checksum: &str,
    generation: u64,
    phase: &str,
) -> Value {
    let record = json!({
        "version": 1,
        "quarantine": path_text(quarantine),
        "transaction": path_text(transaction),
        "source_prefix": source,
        "tracked_digest": tracked_digest(dest, &format!("{source}/SKILL.md"), checksum),
        "install_state_generation": generation,
        "nonce": "crash"
    });
    let mut transaction_value = record.clone();
    transaction_value["dest"] = json!(path_text(dest));
    transaction_value["phase"] = json!(phase);
    write_json(transaction, &transaction_value);
    record
}

#[test]
fn released_crash_drift_checks_the_new_public_inventory() {
    let root = unique_temp_dir("quarantine-released-drift");
    let state = root.join("state.json");
    let dest = root.join("skills/retired");
    let quarantine = root.join("skills/.retired.vibeguard-quarantine.crash");
    let transaction = root.join("skills/.retired.vibeguard-transaction.crash.json");
    fs::create_dir_all(&dest).unwrap();
    fs::create_dir_all(&quarantine).unwrap();
    fs::write(dest.join("SKILL.md"), "new").unwrap();
    fs::write(quarantine.join("SKILL.md"), "old").unwrap();
    let record = record_and_transaction(
        &dest,
        &quarantine,
        &transaction,
        "workflows/retired",
        OLD_SHA,
        6,
        "released",
    );
    write_json(
        &state,
        &json!({
            "version": 1, "generation": 6, "complete": false,
            "files": { path_text(&dest.join("SKILL.md")): {
                "source": "workflows-v2/retired/SKILL.md", "type": "copy",
                "checksum": NEW_SHA
            }},
            "disabled_skill_quarantines": { path_text(&dest): record }
        }),
    );

    let output = bin()
        .args(["setup-state-check-drift", &path_text(&state)])
        .output()
        .unwrap();
    assert_output(
        &output,
        0,
        "---\nTotal tracked: 1, Missing: 0, Drifted: 0\nSTATUS: CLEAN\n",
        "",
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn retired_manifest_skill_carries_an_orphan_intent_from_custom_codex_home() {
    let root = unique_temp_dir("quarantine-orphan-intent-carry");
    let home = root.join("home");
    let skills = root.join("custom-codex/skills");
    let dest = skills.join("retired");
    let quarantine = skills.join(".retired.vibeguard-quarantine.crash");
    let transaction = skills.join(".retired.vibeguard-transaction.crash.json");
    let current = root.join("install-state.json");
    let previous = root.join("install-state.previous.json");
    fs::create_dir_all(&quarantine).unwrap();
    fs::write(quarantine.join("SKILL.md"), "hello").unwrap();
    record_and_transaction(
        &dest,
        &quarantine,
        &transaction,
        "workflows/retired",
        HELLO_SHA,
        6,
        "intent",
    );
    write_json(
        &current,
        &json!({
            "version": 1, "generation": 6, "complete": false, "files": {}
        }),
    );
    write_json(
        &previous,
        &json!({
            "version": 1, "generation": 5, "complete": true,
            "files": { path_text(&dest.join("SKILL.md")): {
                "source": "workflows/retired/SKILL.md", "type": "copy",
                "checksum": HELLO_SHA
            }}
        }),
    );

    let initialized = bin()
        .args([
            "setup-state-init",
            &path_text(&current),
            "core",
            "",
            "6",
            "",
            &path_text(&previous),
            "",
            &path_text(&skills),
        ])
        .env("HOME", &home)
        .output()
        .unwrap();
    assert_output(&initialized, 0, "", "");
    let carried = read_json(&current);
    assert!(
        carried["files"]
            .get(path_text(&dest.join("SKILL.md")))
            .is_some()
    );
    assert!(
        carried["disabled_skill_quarantines"]
            .get(path_text(&dest))
            .is_some()
    );

    let count = bin()
        .args(["setup-state-quarantine-count", &path_text(&current)])
        .output()
        .unwrap();
    assert_output(&count, 0, "1\n", "");
    let resumed = bin()
        .args([
            "setup-state-quarantine-managed-tree",
            &path_text(&current),
            &path_text(&previous),
            &path_text(&dest),
            "workflows/retired",
        ])
        .output()
        .unwrap();
    assert_output(
        &resumed,
        0,
        &format!("QUARANTINED\t{}\n", path_text(&quarantine)),
        "",
    );
    assert_eq!(read_json(&transaction)["phase"], "committed");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn orphan_intent_carry_rejects_changed_quarantine_without_mutating_state() {
    let root = unique_temp_dir("quarantine-orphan-intent-changed");
    let home = root.join("home");
    let skills = home.join(".codex/skills");
    let dest = skills.join("retired");
    let quarantine = skills.join(".retired.vibeguard-quarantine.crash");
    let transaction = skills.join(".retired.vibeguard-transaction.crash.json");
    let current = root.join("install-state.json");
    let previous = root.join("install-state.previous.json");
    fs::create_dir_all(&quarantine).unwrap();
    fs::write(quarantine.join("SKILL.md"), "changed").unwrap();
    record_and_transaction(
        &dest,
        &quarantine,
        &transaction,
        "workflows/retired",
        HELLO_SHA,
        6,
        "intent",
    );
    write_json(
        &current,
        &json!({
            "version": 1, "generation": 6, "complete": false, "files": {}
        }),
    );
    write_json(
        &previous,
        &json!({
            "version": 1, "generation": 5, "complete": true,
            "files": { path_text(&dest.join("SKILL.md")): {
                "source": "workflows/retired/SKILL.md", "type": "copy",
                "checksum": HELLO_SHA
            }}
        }),
    );
    let before = fs::read(&current).unwrap();
    let rejected = bin()
        .args([
            "setup-state-init",
            &path_text(&current),
            "core",
            "",
            "6",
            "",
            &path_text(&previous),
        ])
        .env("HOME", &home)
        .output()
        .unwrap();
    assert_eq!(rejected.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&rejected.stderr).contains("UNOWNED:checksum_mismatch"));
    assert_eq!(fs::read(&current).unwrap(), before);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn pre_rename_intent_is_left_for_normal_transaction_recovery() {
    let root = unique_temp_dir("quarantine-pre-rename-intent");
    let home = root.join("home");
    let skills = home.join(".codex/skills");
    let dest = skills.join("retired");
    let quarantine = skills.join(".retired.vibeguard-quarantine.crash");
    let transaction = skills.join(".retired.vibeguard-transaction.crash.json");
    let current = root.join("install-state.json");
    let previous = root.join("install-state.previous.json");
    fs::create_dir_all(&dest).unwrap();
    fs::write(dest.join("SKILL.md"), "hello").unwrap();
    record_and_transaction(
        &dest,
        &quarantine,
        &transaction,
        "workflows/retired",
        HELLO_SHA,
        6,
        "intent",
    );
    write_json(
        &current,
        &json!({
            "version": 1, "generation": 6, "complete": false, "files": {}
        }),
    );
    write_json(
        &previous,
        &json!({
            "version": 1, "generation": 5, "complete": true,
            "files": { path_text(&dest.join("SKILL.md")): {
                "source": "workflows/retired/SKILL.md", "type": "copy",
                "checksum": HELLO_SHA
            }}
        }),
    );

    let initialized = bin()
        .args([
            "setup-state-init",
            &path_text(&current),
            "core",
            "",
            "6",
            "retired",
            &path_text(&previous),
        ])
        .env("HOME", &home)
        .output()
        .unwrap();
    assert_output(&initialized, 0, "", "");
    assert!(dest.is_dir());
    assert!(!quarantine.exists());
    assert_eq!(read_json(&transaction)["phase"], "intent");
    assert!(
        read_json(&current)
            .get("disabled_skill_quarantines")
            .is_none()
    );

    let recovered = bin()
        .args([
            "setup-state-quarantine-managed-tree",
            &path_text(&current),
            &path_text(&previous),
            &path_text(&dest),
            "workflows/retired",
        ])
        .output()
        .unwrap();
    assert_eq!(recovered.status.code(), Some(0));
    assert!(!dest.exists());
    assert_eq!(read_json(&transaction)["phase"], "restored");
    let count = bin()
        .args(["setup-state-quarantine-count", &path_text(&current)])
        .output()
        .unwrap();
    assert_output(&count, 0, "1\n", "");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn orphan_intent_with_no_public_or_hidden_tree_fails_init_without_mutation() {
    let root = unique_temp_dir("quarantine-orphan-intent-missing-both");
    let home = root.join("home");
    let skills = home.join(".codex/skills");
    let dest = skills.join("retired");
    let quarantine = skills.join(".retired.vibeguard-quarantine.crash");
    let transaction = skills.join(".retired.vibeguard-transaction.crash.json");
    let current = root.join("install-state.json");
    let previous = root.join("install-state.previous.json");
    fs::create_dir_all(&skills).unwrap();
    record_and_transaction(
        &dest,
        &quarantine,
        &transaction,
        "workflows/retired",
        HELLO_SHA,
        6,
        "intent",
    );
    write_json(
        &current,
        &json!({
            "version": 1, "generation": 6, "complete": false, "files": {}
        }),
    );
    write_json(
        &previous,
        &json!({
            "version": 1, "generation": 5, "complete": true,
            "files": { path_text(&dest.join("SKILL.md")): {
                "source": "workflows/retired/SKILL.md", "type": "copy",
                "checksum": HELLO_SHA
            }}
        }),
    );
    let before = fs::read(&current).unwrap();
    let rejected = bin()
        .args([
            "setup-state-init",
            &path_text(&current),
            "core",
            "",
            "6",
            "",
            &path_text(&previous),
        ])
        .env("HOME", &home)
        .output()
        .unwrap();
    assert_eq!(rejected.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&rejected.stderr).contains("no recoverable tree"));
    assert_eq!(fs::read(&current).unwrap(), before);
    fs::remove_dir_all(root).unwrap();
}
