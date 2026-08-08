mod common;

use common::{assert_output, bin, path_text, unique_temp_dir, write_json};
use serde_json::{Value, json};
use std::fs;
use std::path::PathBuf;
use std::process::Output;

const SOURCE: &str = "skills/plan-flow";
const MANAGED_CHECKSUM: &str =
    "sha256:5b4bc29f140e30c01417d810e700ecc54a84a0107566d84215b42e5742ef8d96";

struct Fixture {
    root: PathBuf,
    state: PathBuf,
    previous: PathBuf,
    skill: PathBuf,
}

impl Fixture {
    fn new(label: &str) -> Self {
        let root = unique_temp_dir(label);
        let state = root.join("state.json");
        let previous = root.join("previous.json");
        let skill = root.join("skills/plan-flow");
        fs::create_dir_all(root.join("home")).expect("home should be created");
        fs::create_dir_all(&skill).expect("skill should be created");
        fs::write(skill.join("SKILL.md"), "managed\n").expect("skill should be written");
        write_json(
            &state,
            &json!({"version": 1, "generation": 2, "complete": false, "files": {}}),
        );
        write_json(
            &previous,
            &json!({
                "version": 1,
                "generation": 1,
                "complete": true,
                "files": {
                    path_text(&skill.join("SKILL.md")): {
                        "source": "skills/plan-flow/SKILL.md",
                        "type": "copy",
                        "checksum": MANAGED_CHECKSUM
                    }
                }
            }),
        );
        Self {
            root,
            state,
            previous,
            skill,
        }
    }

    fn args_for(&self, command: &str) -> Vec<String> {
        vec![
            command.into(),
            path_text(&self.state),
            path_text(&self.previous),
            path_text(&self.skill),
            SOURCE.into(),
        ]
    }

    fn run(&self, env: &[(&str, &str)]) -> Output {
        self.run_command("setup-state-quarantine-managed-tree", env)
    }

    fn run_command(&self, command: &str, env: &[(&str, &str)]) -> Output {
        self.run_command_source(command, SOURCE, env)
    }

    fn run_command_source(&self, command: &str, source: &str, env: &[(&str, &str)]) -> Output {
        let mut process = bin();
        let mut args = self.args_for(command);
        *args.last_mut().expect("source argument should exist") = source.into();
        process
            .args(args)
            .env("HOME", self.root.join("home"))
            .current_dir(&self.root);
        for (key, value) in env {
            process.env(key, value);
        }
        process
            .output()
            .expect("managed-tree quarantine should run")
    }

    fn state(&self) -> Value {
        serde_json::from_slice(&fs::read(&self.state).expect("state should read"))
            .expect("state should parse")
    }

    fn record(&self) -> Option<Value> {
        let state = self.state();
        state
            .get("disabled_skill_quarantines")?
            .get(path_text(&self.skill))
            .cloned()
    }

    fn quarantines(&self) -> Vec<PathBuf> {
        sibling_paths(&self.skill, ".plan-flow.vibeguard-quarantine.")
    }

    fn transactions(&self) -> Vec<PathBuf> {
        sibling_paths(&self.skill, ".plan-flow.vibeguard-transaction.")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn sibling_paths(path: &std::path::Path, prefix: &str) -> Vec<PathBuf> {
    let mut paths = fs::read_dir(path.parent().unwrap())
        .expect("parent should be readable")
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|candidate| {
            candidate
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with(prefix))
        })
        .collect::<Vec<_>>();
    paths.sort();
    paths
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

#[test]
fn command_rejects_invalid_arity() {
    let root = unique_temp_dir("quarantine-managed-tree-arity");
    fs::create_dir_all(root.join("home")).expect("home should be created");
    let output = bin()
        .arg("setup-state-quarantine-managed-tree")
        .env("HOME", root.join("home"))
        .current_dir(&root)
        .output()
        .expect("arity command should run");
    assert_output(
        &output,
        1,
        "",
        "vibeguard-runtime error: Usage: vibeguard-runtime setup-state-quarantine-managed-tree <state-file> <previous-state-file> <dest-dir> <source-prefix>\n",
    );
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn exact_managed_tree_is_durably_quarantined_without_deletion() {
    let fixture = Fixture::new("quarantine-managed-tree-success");
    let output = fixture.run(&[]);
    assert_eq!(output.status.code(), Some(0), "{}", stderr(&output));
    assert!(String::from_utf8_lossy(&output.stdout).starts_with("QUARANTINED\t"));
    assert!(!fixture.skill.exists());
    let quarantines = fixture.quarantines();
    assert_eq!(quarantines.len(), 1);
    assert_eq!(
        fs::read_to_string(quarantines[0].join("SKILL.md")).unwrap(),
        "managed\n"
    );
    let record = fixture.record().expect("state locator should be committed");
    assert_eq!(record["version"], 1);
    assert_eq!(record["quarantine"], path_text(&quarantines[0]));
    assert_eq!(record["source_prefix"], SOURCE);
    assert_eq!(record["install_state_generation"], 2);
    assert!(
        record["tracked_digest"]
            .as_str()
            .unwrap()
            .starts_with("sha256:")
    );
    let transactions = fixture.transactions();
    assert_eq!(transactions.len(), 1);
    let transaction: Value = serde_json::from_slice(&fs::read(&transactions[0]).unwrap()).unwrap();
    assert_eq!(transaction["phase"], "committed");
}

#[test]
fn compatibility_remove_command_never_deletes_quarantine() {
    let fixture = Fixture::new("quarantine-managed-tree-compat");
    let output = fixture.run_command("setup-state-remove-managed-tree", &[]);
    assert_eq!(output.status.code(), Some(0), "{}", stderr(&output));
    assert!(!fixture.skill.exists());
    assert!(fixture.quarantines()[0].join("SKILL.md").is_file());
}

#[test]
fn reenabled_canonical_tree_can_be_quarantined_again() {
    let fixture = Fixture::new("quarantine-managed-tree-reenable-cycle");
    let first = fixture.run(&[]);
    assert_eq!(first.status.code(), Some(0), "{}", stderr(&first));
    let first_quarantine = fixture.quarantines()[0].clone();
    let mut previous: Value =
        serde_json::from_slice(&fs::read(&fixture.previous).unwrap()).unwrap();
    previous["disabled_skill_quarantines"] = fixture.state()["disabled_skill_quarantines"].clone();
    write_json(&fixture.previous, &previous);
    fs::create_dir_all(&fixture.skill).expect("public skill should be recreated");
    fs::write(fixture.skill.join("SKILL.md"), "managed\n")
        .expect("canonical public skill should be restored");

    let released = fixture.run_command("setup-state-release-quarantined-tree", &[]);
    assert_eq!(released.status.code(), Some(0), "{}", stderr(&released));
    assert_eq!(String::from_utf8_lossy(&released.stdout), "RELEASED\n");
    assert!(fixture.record().is_none());
    assert!(first_quarantine.join("SKILL.md").is_file());
    let first_transaction: Value =
        serde_json::from_slice(&fs::read(&fixture.transactions()[0]).unwrap()).unwrap();
    assert_eq!(first_transaction["phase"], "released");

    let second = fixture.run(&[]);
    assert_eq!(second.status.code(), Some(0), "{}", stderr(&second));
    assert!(!fixture.skill.exists());
    assert_eq!(fixture.quarantines().len(), 2);
    assert!(first_quarantine.join("SKILL.md").is_file());
    assert!(fixture.record().is_some());
}

#[test]
fn interrupted_reenable_release_is_retryable_without_data_loss() {
    let fixture = Fixture::new("quarantine-managed-tree-release-retry");
    let first = fixture.run(&[]);
    assert_eq!(first.status.code(), Some(0), "{}", stderr(&first));
    fs::create_dir_all(&fixture.skill).expect("public skill should be recreated");
    fs::write(fixture.skill.join("SKILL.md"), "managed\n")
        .expect("canonical public skill should be restored");

    let interrupted = fixture.run_command(
        "setup-state-release-quarantined-tree",
        &[("VIBEGUARD_TEST_RELEASE_AFTER_TRANSACTION", "1")],
    );
    assert_eq!(interrupted.status.code(), Some(1));
    assert!(stderr(&interrupted).contains("injected failure after quarantine release"));
    assert!(fixture.record().is_some());
    assert!(fixture.skill.join("SKILL.md").is_file());
    assert!(fixture.quarantines()[0].join("SKILL.md").is_file());
    let transaction: Value =
        serde_json::from_slice(&fs::read(&fixture.transactions()[0]).unwrap()).unwrap();
    assert_eq!(transaction["phase"], "released");

    let retry = fixture.run_command("setup-state-release-quarantined-tree", &[]);
    assert_eq!(retry.status.code(), Some(0), "{}", stderr(&retry));
    assert!(fixture.record().is_none());
    assert!(fixture.skill.join("SKILL.md").is_file());
    assert!(fixture.quarantines()[0].join("SKILL.md").is_file());
}

#[test]
fn released_transaction_from_old_source_does_not_block_new_source() {
    let fixture = Fixture::new("quarantine-managed-tree-source-move");
    let first = fixture.run(&[]);
    assert_eq!(first.status.code(), Some(0), "{}", stderr(&first));
    fs::create_dir_all(&fixture.skill).expect("public skill should be recreated");
    fs::write(fixture.skill.join("SKILL.md"), "managed\n")
        .expect("canonical public skill should be restored");
    let released = fixture.run_command("setup-state-release-quarantined-tree", &[]);
    assert_eq!(released.status.code(), Some(0), "{}", stderr(&released));

    let moved = fixture.run_command_source(
        "setup-state-quarantine-managed-tree",
        "skills-v2/plan-flow",
        &[],
    );
    assert_eq!(
        moved.status.code(),
        Some(1),
        "test fixture should reach ownership validation"
    );
    assert!(
        !stderr(&moved).contains("managed-tree transaction does not match request"),
        "terminal old-source transaction must be ignored: {}",
        stderr(&moved)
    );
}

/// A manifest that moves a disabled skill's source directory while keeping its
/// public name must not strand the installation. The active quarantine already
/// carries the source prefix its tracked inventory was recorded under, so the
/// request is idempotent: report the existing quarantine instead of aborting
/// setup after it has already refreshed the installed snapshot.
#[test]
fn active_quarantine_survives_a_manifest_source_move() {
    let fixture = Fixture::new("quarantine-managed-tree-active-source-move");
    let first = fixture.run(&[]);
    assert_eq!(first.status.code(), Some(0), "{}", stderr(&first));
    let quarantine = fixture.quarantines()[0].clone();

    let disabled_again = fixture.run_command_source(
        "setup-state-quarantine-managed-tree",
        "skills-v2/plan-flow",
        &[],
    );
    assert_eq!(
        disabled_again.status.code(),
        Some(0),
        "{}",
        stderr(&disabled_again)
    );
    assert!(
        String::from_utf8_lossy(&disabled_again.stdout)
            .contains(&format!("QUARANTINED\t{}", quarantine.display()))
    );
    // The move must not silently re-attribute ownership: the record and the
    // retained bytes still belong to the original quarantine.
    assert!(fixture.record().is_some());
    assert!(quarantine.join("SKILL.md").is_file());
    assert_eq!(fixture.quarantines().len(), 1);
}

#[test]
fn active_quarantine_can_be_released_after_a_manifest_source_move() {
    let fixture = Fixture::new("quarantine-managed-tree-release-source-move");
    let first = fixture.run(&[]);
    assert_eq!(first.status.code(), Some(0), "{}", stderr(&first));
    let quarantine = fixture.quarantines()[0].clone();

    // Simulate setup refreshing the canonical install snapshot from its new
    // manifest source before releasing the quarantine recorded under v1.
    let mut current = fixture.state();
    current["files"][path_text(&fixture.skill.join("SKILL.md"))]["source"] =
        json!("skills-v2/plan-flow/SKILL.md");
    write_json(&fixture.state, &current);
    fs::create_dir_all(&fixture.skill).expect("public skill should be recreated");
    fs::write(fixture.skill.join("SKILL.md"), "managed\n")
        .expect("canonical public skill should be restored");

    let released = fixture.run_command_source(
        "setup-state-release-quarantined-tree",
        "skills-v2/plan-flow",
        &[],
    );
    assert_eq!(released.status.code(), Some(0), "{}", stderr(&released));
    assert_eq!(String::from_utf8_lossy(&released.stdout), "RELEASED\n");
    assert!(fixture.record().is_none());
    assert!(fixture.skill.join("SKILL.md").is_file());
    assert!(quarantine.join("SKILL.md").is_file());
    let transaction: Value =
        serde_json::from_slice(&fs::read(&fixture.transactions()[0]).unwrap()).unwrap();
    assert_eq!(transaction["phase"], "released");
    assert_eq!(transaction["source_prefix"], SOURCE);
}

#[test]
fn release_prunes_stale_tracked_files_removed_from_canonical_source() {
    let fixture = Fixture::new("quarantine-managed-tree-release-prune");
    let first = fixture.run(&[]);
    assert_eq!(first.status.code(), Some(0), "{}", stderr(&first));
    let stale = fixture.skill.join("REMOVED.md");
    let mut state = fixture.state();
    state["files"][path_text(&stale)] = json!({
        "source": "skills/plan-flow/REMOVED.md",
        "type": "copy",
        "checksum": MANAGED_CHECKSUM
    });
    write_json(&fixture.state, &state);
    fs::create_dir_all(&fixture.skill).expect("public skill should be recreated");
    fs::write(fixture.skill.join("SKILL.md"), "managed\n")
        .expect("canonical public skill should be restored");

    let released = fixture.run_command("setup-state-release-quarantined-tree", &[]);
    assert_eq!(released.status.code(), Some(0), "{}", stderr(&released));
    assert!(fixture.state()["files"].get(path_text(&stale)).is_none());
}

#[test]
fn release_transaction_failures_do_not_prune_install_state() {
    for corrupt in [false, true] {
        let fixture = Fixture::new(if corrupt {
            "quarantine-managed-tree-corrupt-release-transaction"
        } else {
            "quarantine-managed-tree-missing-release-transaction"
        });
        assert_eq!(fixture.run(&[]).status.code(), Some(0));
        let stale = fixture.skill.join("REMOVED.md");
        let mut state = fixture.state();
        state["files"][path_text(&stale)] = json!({
            "source": "skills/plan-flow/REMOVED.md",
            "type": "copy",
            "checksum": MANAGED_CHECKSUM
        });
        write_json(&fixture.state, &state);
        fs::create_dir_all(&fixture.skill).expect("public skill should be recreated");
        fs::write(fixture.skill.join("SKILL.md"), "managed\n")
            .expect("canonical public skill should be restored");
        let transaction = fixture.transactions()[0].clone();
        if corrupt {
            fs::write(transaction, "{").expect("transaction should be corrupted");
        } else {
            fs::remove_file(transaction).expect("transaction should be removed");
        }
        let before = fs::read(&fixture.state).expect("state should read before release");
        let released = fixture.run_command("setup-state-release-quarantined-tree", &[]);
        assert_eq!(released.status.code(), Some(1));
        assert_eq!(fs::read(&fixture.state).unwrap(), before);
    }
}

#[test]
fn released_crash_retry_tolerates_previous_stale_inventory() {
    let fixture = Fixture::new("quarantine-managed-tree-released-previous-stale");
    assert_eq!(fixture.run(&[]).status.code(), Some(0));
    let record = fixture.record().expect("active record should exist");
    let stale = fixture.skill.join("REMOVED.md");
    let stale_entry = json!({
        "source": "skills/plan-flow/REMOVED.md",
        "type": "copy",
        "checksum": MANAGED_CHECKSUM
    });
    let mut current = fixture.state();
    current["files"][path_text(&stale)] = stale_entry.clone();
    write_json(&fixture.state, &current);
    let mut previous: Value =
        serde_json::from_slice(&fs::read(&fixture.previous).unwrap()).unwrap();
    previous["files"][path_text(&stale)] = stale_entry;
    previous["disabled_skill_quarantines"] = json!({ path_text(&fixture.skill): record });
    write_json(&fixture.previous, &previous);
    fs::create_dir_all(&fixture.skill).expect("public skill should be recreated");
    fs::write(fixture.skill.join("SKILL.md"), "managed\n")
        .expect("canonical public skill should be restored");

    let interrupted = fixture.run_command(
        "setup-state-release-quarantined-tree",
        &[("VIBEGUARD_TEST_RELEASE_AFTER_TRANSACTION", "1")],
    );
    assert_eq!(interrupted.status.code(), Some(1));
    let previous_preflight = bin()
        .args([
            "setup-state-quarantine-count",
            &path_text(&fixture.previous),
        ])
        .output()
        .expect("previous-state preflight should run");
    assert_output(&previous_preflight, 0, "1\n", "");

    let retry = fixture.run_command("setup-state-release-quarantined-tree", &[]);
    assert_eq!(retry.status.code(), Some(0), "{}", stderr(&retry));
    assert!(fixture.record().is_none());
    let previous: Value = serde_json::from_slice(&fs::read(&fixture.previous).unwrap()).unwrap();
    assert!(previous.get("disabled_skill_quarantines").is_none());
}

#[test]
fn transaction_scan_ignores_interrupted_atomic_write_temps() {
    let fixture = Fixture::new("quarantine-managed-tree-transaction-temp");
    let temp = fixture
        .skill
        .parent()
        .unwrap()
        .join(".plan-flow.vibeguard-transaction.abandoned.tmp.42");
    fs::write(&temp, "{").expect("staged temp should be written");
    let output = fixture.run(&[]);
    assert_eq!(output.status.code(), Some(0), "{}", stderr(&output));
    assert!(
        temp.is_file(),
        "unpublished temp is ignored rather than parsed"
    );
    assert!(fixture.record().is_some());
}

#[test]
fn crash_after_rename_recovers_then_commits_without_deletion() {
    let fixture = Fixture::new("quarantine-managed-tree-rename-crash");
    let crashed = fixture.run(&[("VIBEGUARD_TEST_QUARANTINE_AFTER_RENAME", "1")]);
    assert_eq!(crashed.status.code(), Some(1));
    assert!(stderr(&crashed).contains("injected failure after quarantine rename"));
    assert!(!fixture.skill.exists());
    assert_eq!(fixture.quarantines().len(), 1);
    assert!(fixture.record().is_none());

    let retry = fixture.run(&[]);
    assert_eq!(retry.status.code(), Some(0), "{}", stderr(&retry));
    assert!(!fixture.skill.exists());
    assert_eq!(fixture.quarantines().len(), 1);
    assert!(fixture.quarantines()[0].join("SKILL.md").is_file());
    assert!(fixture.record().is_some());
}

#[test]
fn late_failure_after_state_publish_is_committed_on_retry() {
    let fixture = Fixture::new("quarantine-managed-tree-late-failure");
    let failed = fixture.run(&[("VIBEGUARD_TEST_QUARANTINE_AFTER_STATE", "1")]);
    assert_eq!(failed.status.code(), Some(1));
    assert!(stderr(&failed).contains("injected failure after install-state publish"));
    assert!(!fixture.skill.exists());
    assert!(fixture.record().is_some());
    assert!(fixture.quarantines()[0].join("SKILL.md").is_file());

    let retry = fixture.run(&[]);
    assert_eq!(retry.status.code(), Some(0), "{}", stderr(&retry));
    assert!(String::from_utf8_lossy(&retry.stdout).starts_with("QUARANTINED\t"));
    assert!(!fixture.skill.exists());
    assert!(fixture.quarantines()[0].join("SKILL.md").is_file());
}

#[test]
fn destination_collisions_fail_before_public_mutation() {
    let fixture = Fixture::new("quarantine-managed-tree-collision");
    let before = fs::read(fixture.skill.join("SKILL.md")).expect("managed bytes should read");
    let output = fixture.run(&[("VIBEGUARD_TEST_REMOVE_COLLIDE_ALL", "1")]);
    assert_eq!(output.status.code(), Some(1));
    assert!(stderr(&output).contains("failed to reserve unique quarantine"));
    assert_eq!(fs::read(fixture.skill.join("SKILL.md")).unwrap(), before);
    assert!(fixture.record().is_none());
    assert_eq!(fixture.quarantines().len(), 10);
}

#[test]
fn postverify_mutation_fails_visible_and_preserves_all_data() {
    let fixture = Fixture::new("quarantine-managed-tree-postverify");
    let output = fixture.run(&[(
        "VIBEGUARD_TEST_REMOVE_POSTVERIFY_INJECT",
        "POSTVERIFY_USER_DATA",
    )]);
    assert_eq!(output.status.code(), Some(1));
    assert!(stderr(&output).contains("changed after ownership verification"));
    assert!(!fixture.skill.exists());
    assert!(fixture.record().is_none());
    let quarantine = &fixture.quarantines()[0];
    assert!(quarantine.join("SKILL.md").is_file());
    assert_eq!(
        fs::read_to_string(quarantine.join("POSTVERIFY_USER_DATA")).unwrap(),
        "user-data\n"
    );
}

#[test]
fn concurrent_public_replacement_preserves_both_trees() {
    let fixture = Fixture::new("quarantine-managed-tree-public-replacement");
    let output = fixture.run(&[
        (
            "VIBEGUARD_TEST_REMOVE_POSTVERIFY_INJECT",
            "POSTVERIFY_USER_DATA",
        ),
        ("VIBEGUARD_TEST_REMOVE_PUBLIC_REPLACEMENT", "custom\n"),
    ]);
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(
        fs::read_to_string(fixture.skill.join("custom.txt")).unwrap(),
        "custom\n"
    );
    let quarantine = &fixture.quarantines()[0];
    assert!(quarantine.join("SKILL.md").is_file());
    assert!(quarantine.join("POSTVERIFY_USER_DATA").is_file());
    assert!(fixture.record().is_none());
}

#[test]
fn unowned_public_path_fails_and_never_installed_absence_is_idempotent() {
    let fixture = Fixture::new("quarantine-managed-tree-unowned");
    let wrong_source = {
        let mut args = fixture.args_for("setup-state-quarantine-managed-tree");
        *args.last_mut().unwrap() = "skills/not-plan-flow".into();
        bin()
            .args(args)
            .env("HOME", fixture.root.join("home"))
            .current_dir(&fixture.root)
            .output()
            .expect("unowned command should run")
    };
    assert_eq!(wrong_source.status.code(), Some(1));
    assert!(fixture.skill.join("SKILL.md").is_file());

    fs::remove_dir_all(&fixture.skill).expect("skill should be removed for replay");
    let replay = fixture.run(&[]);
    assert_output(&replay, 0, "ABSENT\n", "");
}

#[cfg(unix)]
#[test]
fn symlink_and_special_paths_fail_closed() {
    use std::os::unix::fs::symlink;

    let symlink_fixture = Fixture::new("quarantine-managed-tree-symlink");
    let real_skill = symlink_fixture.root.join("real-skill");
    fs::rename(&symlink_fixture.skill, &real_skill).expect("skill should move");
    symlink(&real_skill, &symlink_fixture.skill).expect("skill symlink should be created");
    let symlink_output = symlink_fixture.run(&[]);
    assert_eq!(symlink_output.status.code(), Some(1));
    assert!(
        fs::symlink_metadata(&symlink_fixture.skill)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert!(real_skill.join("SKILL.md").is_file());

    let special_fixture = Fixture::new("quarantine-managed-tree-special");
    let fifo = special_fixture.skill.join("user-fifo");
    let fifo_text = std::ffi::CString::new(path_text(&fifo)).expect("fifo path should be C-safe");
    assert_eq!(unsafe { libc::mkfifo(fifo_text.as_ptr(), 0o600) }, 0);
    let special_output = special_fixture.run(&[]);
    assert_eq!(special_output.status.code(), Some(1));
    assert!(fifo.exists());
    assert!(special_fixture.skill.join("SKILL.md").is_file());
}

#[test]
fn interrupted_release_is_completed_before_a_new_quarantine() {
    let fixture = Fixture::new("quarantine-managed-tree-released-then-disable");
    let first = fixture.run(&[]);
    assert_eq!(first.status.code(), Some(0), "{}", stderr(&first));
    fs::create_dir_all(&fixture.skill).expect("public skill should be recreated");
    fs::write(fixture.skill.join("SKILL.md"), "managed\n")
        .expect("canonical public skill should be restored");

    // Persist the released phase but fail before the active record is removed.
    let interrupted = fixture.run_command(
        "setup-state-release-quarantined-tree",
        &[("VIBEGUARD_TEST_RELEASE_AFTER_TRANSACTION", "1")],
    );
    assert_eq!(interrupted.status.code(), Some(1));
    assert!(fixture.record().is_some());

    // Disabling again must finish the interrupted release instead of rejecting
    // every attempt because the stale record has no non-terminal transaction.
    let disabled = fixture.run(&[]);
    assert_eq!(disabled.status.code(), Some(0), "{}", stderr(&disabled));
    assert!(
        !stderr(&disabled).contains("install-state quarantine locator has no exact transaction"),
        "stale released record must not permanently block quarantine: {}",
        stderr(&disabled)
    );
    assert!(!fixture.skill.exists());
    assert!(fixture.record().is_some());
}
