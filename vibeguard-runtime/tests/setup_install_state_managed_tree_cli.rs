mod common;

use common::{assert_output, path_text, run_with_home as run, unique_temp_dir, write_json};
use serde_json::json;
use std::fs;

#[test]
fn managed_tree_lookup_fails_on_bad_state_and_verifies_exact_ownership() {
    let root = unique_temp_dir("install_state_managed_tree");
    fs::create_dir_all(root.join("home")).expect("temp root should be created");
    let state = root.join("state.json");
    let skill = root.join("skills/plan-flow");
    let managed_file = skill.join("SKILL.md");
    fs::create_dir_all(&skill).expect("managed skill should be created");
    fs::write(&managed_file, "managed\n").expect("managed file should be written");

    fs::write(&state, "{").expect("malformed state should be written");
    let state_text = path_text(&state);
    let skill_text = path_text(&skill);
    for command in [
        "setup-state-list-tracked-under",
        "setup-state-verify-managed-tree",
    ] {
        let mut args = vec![command, state_text.as_str(), skill_text.as_str()];
        let source_prefix = "skills/plan-flow";
        if command == "setup-state-verify-managed-tree" {
            args.push(source_prefix);
        }
        let output = run(&root, &args);
        assert_eq!(output.status.code(), Some(1));
        assert!(output.stdout.is_empty());
    }

    write_json(
        &state,
        &json!({
            "version": 1,
            "files": []
        }),
    );
    let invalid_files = run(
        &root,
        &[
            "setup-state-list-tracked-under",
            &path_text(&state),
            &path_text(&skill),
        ],
    );
    assert_output(
        &invalid_files,
        1,
        "",
        "vibeguard-runtime error: install-state files must be an object\n",
    );

    for invalid_state in [
        r#"{"version":"1","files":{}}"#,
        r#"{"version":1,"files":{"/managed":[]}}"#,
        r#"{"version":1,"files":{"/managed":{"source":7,"type":"copy","checksum":"sha256:5b4bc29f140e30c01417d810e700ecc54a84a0107566d84215b42e5742ef8d96"}}}"#,
        r#"{"version":1,"files":{"/managed":{"source":"skills/plan-flow/SKILL.md","type":"copy","checksum":"bad"}}}"#,
    ] {
        fs::write(&state, invalid_state).expect("invalid state should be written");
        let invalid_entry = run(
            &root,
            &["setup-state-list-tracked-under", &state_text, &skill_text],
        );
        assert_eq!(invalid_entry.status.code(), Some(1));
        assert!(invalid_entry.stdout.is_empty());
    }

    write_json(
        &state,
        &json!({
            "version": 1,
            "files": {
                path_text(&managed_file): {
                    "source": "skills/plan-flow/SKILL.md",
                    "type": "copy",
                    "checksum": "sha256:5b4bc29f140e30c01417d810e700ecc54a84a0107566d84215b42e5742ef8d96"
                }
            }
        }),
    );
    let owned = run(
        &root,
        &[
            "setup-state-verify-managed-tree",
            &path_text(&state),
            &path_text(&skill),
            "skills/plan-flow",
        ],
    );
    assert_output(&owned, 0, "OWNED\n", "");

    let quarantined = root.join("skills/.plan-flow.vibeguard-remove");
    fs::rename(&skill, &quarantined).expect("managed skill should be quarantined");
    let relocated_owned = run(
        &root,
        &[
            "setup-state-verify-managed-tree",
            &path_text(&state),
            &path_text(&quarantined),
            "skills/plan-flow",
            &path_text(&skill),
        ],
    );
    assert_output(&relocated_owned, 0, "OWNED\n", "");
    fs::rename(&quarantined, &skill).expect("managed skill should be restored");

    fs::write(skill.join("user.txt"), "custom\n").expect("custom file should be written");
    let extra_file = run(
        &root,
        &[
            "setup-state-verify-managed-tree",
            &path_text(&state),
            &path_text(&skill),
            "skills/plan-flow",
        ],
    );
    assert_output(&extra_file, 0, "UNOWNED:untracked_path\n", "");

    fs::remove_file(skill.join("user.txt")).expect("custom file should be removed");
    fs::write(&managed_file, "modified\n").expect("managed file should be modified");
    let modified = run(
        &root,
        &[
            "setup-state-verify-managed-tree",
            &path_text(&state),
            &path_text(&skill),
            "skills/plan-flow",
        ],
    );
    assert_output(&modified, 0, "UNOWNED:checksum_mismatch\n", "");

    #[cfg(unix)]
    {
        use std::os::unix::fs::symlink;

        fs::write(&managed_file, "managed\n").expect("managed file should be restored");
        symlink(&managed_file, skill.join("user-link")).expect("user symlink should be created");
        let special_entry = run(
            &root,
            &[
                "setup-state-verify-managed-tree",
                &path_text(&state),
                &path_text(&skill),
                "skills/plan-flow",
            ],
        );
        assert_output(&special_entry, 0, "UNOWNED:unsupported_path_type\n", "");
        fs::remove_file(skill.join("user-link")).expect("user symlink should be removed");
    }

    write_json(
        &state,
        &json!({
            "version": 2,
            "files": {}
        }),
    );
    let unsupported = run(
        &root,
        &[
            "setup-state-list-tracked-under",
            &path_text(&state),
            &path_text(&skill),
        ],
    );
    assert_eq!(unsupported.status.code(), Some(1));
    assert!(unsupported.stdout.is_empty());

    fs::remove_dir_all(root).expect("temp root should be removed");
}
