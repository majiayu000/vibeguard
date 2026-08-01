mod common;

use common::{assert_output, bin, path_text, unique_temp_dir, write_json};
use serde_json::json;
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
            &json!({
                "version": 1,
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

    fn args(&self) -> Vec<String> {
        vec![
            "setup-state-remove-managed-tree".into(),
            path_text(&self.state),
            path_text(&self.previous),
            path_text(&self.skill),
            SOURCE.into(),
        ]
    }

    fn run(&self, env: &[(&str, &str)]) -> Output {
        let mut command = bin();
        command
            .args(self.args())
            .env("HOME", self.root.join("home"))
            .current_dir(&self.root);
        for (key, value) in env {
            command.env(key, value);
        }
        command.output().expect("managed-tree removal should run")
    }

    fn quarantines(&self) -> Vec<PathBuf> {
        let mut paths = fs::read_dir(self.skill.parent().unwrap())
            .expect("skill parent should be readable")
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with(".plan-flow.vibeguard-remove."))
            })
            .collect::<Vec<_>>();
        paths.sort();
        paths
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

#[test]
fn command_rejects_invalid_arity() {
    let root = unique_temp_dir("remove-managed-tree-arity");
    fs::create_dir_all(root.join("home")).expect("home should be created");
    let output = bin()
        .arg("setup-state-remove-managed-tree")
        .env("HOME", root.join("home"))
        .current_dir(&root)
        .output()
        .expect("arity command should run");
    assert_output(
        &output,
        1,
        "",
        "vibeguard-runtime error: Usage: vibeguard-runtime setup-state-remove-managed-tree <state-file> <previous-state-file> <dest-dir> <source-prefix>\n",
    );
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn exact_managed_tree_is_removed_without_quarantine_residue() {
    let fixture = Fixture::new("remove-managed-tree-success");
    let output = fixture.run(&[]);
    assert_output(&output, 0, "REMOVED\n", "");
    assert!(!fixture.skill.exists());
    assert!(fixture.quarantines().is_empty());
}

#[test]
fn destination_collisions_fail_before_public_mutation() {
    let fixture = Fixture::new("remove-managed-tree-collision");
    let before = fs::read(fixture.skill.join("SKILL.md")).expect("managed bytes should read");
    let output = fixture.run(&[("VIBEGUARD_TEST_REMOVE_COLLIDE_ALL", "1")]);
    assert_eq!(output.status.code(), Some(1));
    assert!(stderr(&output).contains("failed to reserve unique quarantine"));
    assert_eq!(
        fs::read(fixture.skill.join("SKILL.md")).expect("public bytes should remain"),
        before
    );
    let quarantines = fixture.quarantines();
    assert_eq!(quarantines.len(), 10);
    assert!(
        quarantines
            .iter()
            .all(|path| path.join("collision-sentinel").is_file())
    );
}

#[test]
fn postverify_injection_is_restored_and_never_deleted() {
    let fixture = Fixture::new("remove-managed-tree-postverify");
    let output = fixture.run(&[(
        "VIBEGUARD_TEST_REMOVE_POSTVERIFY_INJECT",
        "POSTVERIFY_DELETED",
    )]);
    assert_eq!(output.status.code(), Some(1));
    assert!(stderr(&output).contains("restored public tree without deletion"));
    assert_eq!(
        fs::read_to_string(fixture.skill.join("POSTVERIFY_DELETED"))
            .expect("injected user data should remain"),
        "user-data\n"
    );
    assert!(fixture.skill.join("SKILL.md").is_file());
    assert!(fixture.quarantines().is_empty());
}

#[test]
fn concurrent_public_replacement_preserves_both_trees() {
    let fixture = Fixture::new("remove-managed-tree-public-replacement");
    let output = fixture.run(&[
        (
            "VIBEGUARD_TEST_REMOVE_POSTVERIFY_INJECT",
            "POSTVERIFY_DELETED",
        ),
        ("VIBEGUARD_TEST_REMOVE_PUBLIC_REPLACEMENT", "custom\n"),
    ]);
    assert_eq!(output.status.code(), Some(1));
    assert!(stderr(&output).contains("public destination was replaced"));
    assert_eq!(
        fs::read_to_string(fixture.skill.join("custom.txt")).expect("replacement should remain"),
        "custom\n"
    );
    let quarantines = fixture.quarantines();
    assert_eq!(quarantines.len(), 1);
    assert!(quarantines[0].join("SKILL.md").is_file());
    assert!(quarantines[0].join("POSTVERIFY_DELETED").is_file());
}

#[test]
fn missing_unowned_and_replayed_paths_fail_without_mutation() {
    let fixture = Fixture::new("remove-managed-tree-unowned");
    let wrong_source = {
        let mut args = fixture.args();
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
    assert_eq!(replay.status.code(), Some(1));
    assert!(stderr(&replay).contains("not an exact VibeGuard-owned copy"));
}

#[cfg(unix)]
#[test]
fn symlink_and_special_paths_fail_closed() {
    use std::os::unix::fs::symlink;

    let symlink_fixture = Fixture::new("remove-managed-tree-symlink");
    let real_skill = symlink_fixture.root.join("real-skill");
    fs::rename(&symlink_fixture.skill, &real_skill).expect("skill should move");
    symlink(&real_skill, &symlink_fixture.skill).expect("skill symlink should be created");
    let symlink_output = symlink_fixture.run(&[]);
    assert_eq!(symlink_output.status.code(), Some(1));
    assert!(
        fs::symlink_metadata(&symlink_fixture.skill)
            .expect("symlink should remain")
            .file_type()
            .is_symlink()
    );
    assert!(real_skill.join("SKILL.md").is_file());

    let special_fixture = Fixture::new("remove-managed-tree-special");
    let fifo = special_fixture.skill.join("user-fifo");
    let fifo_text = std::ffi::CString::new(path_text(&fifo)).expect("fifo path should be C-safe");
    let result = unsafe { libc::mkfifo(fifo_text.as_ptr(), 0o600) };
    assert_eq!(result, 0);
    let special_output = special_fixture.run(&[]);
    assert_eq!(special_output.status.code(), Some(1));
    assert!(fifo.exists());
    assert!(special_fixture.skill.join("SKILL.md").is_file());
}

#[test]
fn invalid_injection_name_restores_without_deleting_data() {
    let fixture = Fixture::new("remove-managed-tree-invalid-injection");
    let output = fixture.run(&[(
        "VIBEGUARD_TEST_REMOVE_POSTVERIFY_INJECT",
        "nested/POSTVERIFY_DELETED",
    )]);
    assert_eq!(output.status.code(), Some(1));
    assert!(stderr(&output).contains("test injection name"));
    assert!(stderr(&output).contains("restored public tree without deletion"));
    assert!(fixture.skill.join("SKILL.md").is_file());
}
