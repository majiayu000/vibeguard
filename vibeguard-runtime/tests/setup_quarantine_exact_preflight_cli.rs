mod common;

use common::{bin, path_text, unique_temp_dir, write_json};
use serde_json::json;
use std::fs;
use std::process::Command;

fn tracked_digest(dest: &std::path::Path, source: &str) -> String {
    let inventory = json!({
        path_text(&dest.join("SKILL.md")): {
            "source": source,
            "type": "copy",
            "checksum": "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
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
        .expect("Python must compute the fixture's canonical inventory digest");
    assert!(output.status.success());
    format!("sha256:{}", String::from_utf8_lossy(&output.stdout).trim())
}

fn active_fixture(
    label: &str,
    phase: &str,
    tracked_source: &str,
    bad_digest: bool,
) -> (std::path::PathBuf, std::path::PathBuf, std::path::PathBuf) {
    let root = unique_temp_dir(label);
    let state = root.join("state.json");
    let dest = root.join("skills/plan-flow");
    let parent = dest.parent().unwrap();
    let quarantine = parent.join(".plan-flow.vibeguard-quarantine.nonce");
    let transaction = parent.join(".plan-flow.vibeguard-transaction.nonce.json");
    fs::create_dir_all(&quarantine).unwrap();
    fs::write(quarantine.join("SKILL.md"), "hello").unwrap();
    let digest = if bad_digest {
        format!("sha256:{}", "a".repeat(64))
    } else {
        tracked_digest(&dest, tracked_source)
    };
    let record = json!({
        "version": 1, "quarantine": path_text(&quarantine),
        "transaction": path_text(&transaction), "source_prefix": "skills/plan-flow",
        "tracked_digest": digest, "install_state_generation": 1, "nonce": "nonce"
    });
    let mut transaction_value = record.clone();
    transaction_value["dest"] = json!(path_text(&dest));
    transaction_value["phase"] = json!(phase);
    write_json(&transaction, &transaction_value);
    write_json(
        &state,
        &json!({
            "version": 1, "files": { path_text(&dest.join("SKILL.md")): {
                "source": tracked_source, "type": "copy",
                "checksum": "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
            }}, "disabled_skill_quarantines": { path_text(&dest): record }
        }),
    );
    (root, state, quarantine)
}

#[test]
fn active_quarantine_preflight_rejects_changed_tracked_bytes_in_every_active_phase() {
    for phase in ["intent", "committed"] {
        let (root, state, quarantine) = active_fixture(
            &format!("quarantine-preflight-changed-{phase}"),
            phase,
            "skills/plan-flow/SKILL.md",
            false,
        );
        let before = fs::read(&state).unwrap();
        fs::write(quarantine.join("SKILL.md"), "changed").unwrap();
        let output = bin()
            .args(["setup-state-quarantine-count", &path_text(&state)])
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(1), "phase {phase} passed");
        assert!(String::from_utf8_lossy(&output.stderr).contains("UNOWNED:checksum_mismatch"));
        assert_eq!(fs::read(&state).unwrap(), before);
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn active_quarantine_preflight_rejects_extra_source_and_digest_drift_without_mutation() {
    for (label, tracked_source, bad_digest, expected) in [
        (
            "extra",
            "skills/plan-flow/SKILL.md",
            false,
            "UNOWNED:untracked_path",
        ),
        (
            "source",
            "skills/other/SKILL.md",
            false,
            "UNOWNED:source_mismatch",
        ),
        (
            "digest",
            "skills/plan-flow/SKILL.md",
            true,
            "tracked digest does not match",
        ),
    ] {
        let (root, state, quarantine) =
            active_fixture(label, "committed", tracked_source, bad_digest);
        if label == "extra" {
            fs::write(quarantine.join("EXTRA.md"), "untracked").unwrap();
        }
        let before = fs::read(&state).unwrap();
        let output = bin()
            .args(["setup-state-quarantine-count", &path_text(&state)])
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(1), "{label} passed preflight");
        assert!(String::from_utf8_lossy(&output.stderr).contains(expected));
        assert_eq!(fs::read(&state).unwrap(), before);
        fs::remove_dir_all(root).unwrap();
    }
}
