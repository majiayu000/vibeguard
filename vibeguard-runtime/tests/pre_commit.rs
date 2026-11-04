//! The commit-time line limit, driven through a real `git commit` with the hook
//! installed for a temporary machine: its own home and global Git configuration.
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

const BIN: &str = env!("CARGO_BIN_EXE_vibeguard-runtime");
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Machine {
    base: PathBuf,
}

impl Drop for Machine {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.base);
    }
}

impl Machine {
    fn new() -> Self {
        let base = std::env::temp_dir().join(format!(
            "vibeguard-pre-commit-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&base).unwrap();
        let machine = Machine {
            base: base.canonicalize().unwrap(),
        };
        machine.config(&["user.email", "t@example.com"]);
        machine.config(&["user.name", "t"]);
        machine
    }
    fn gitconfig(&self) -> PathBuf {
        self.base.join("gitconfig")
    }
    fn git(&self, dir: &Path, args: &[&str]) -> Output {
        Command::new("git")
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", self.gitconfig())
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .args(args)
            .output()
            .unwrap()
    }
    fn config(&self, args: &[&str]) {
        let mut all = vec!["config", "--global"];
        all.extend(args);
        assert!(self.git(&self.base, &all).status.success(), "{args:?}");
    }
    fn hooks_path(&self) -> Option<String> {
        let out = self.git(
            &self.base,
            &["config", "--global", "--get", "core.hooksPath"],
        );
        out.status
            .success()
            .then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
    }
    fn setup(&self, action: &str, extra: &[&str]) -> Output {
        Command::new(BIN)
            .current_dir(&self.base)
            .env("GIT_CONFIG_GLOBAL", self.gitconfig())
            .args([action, "git-size", "--home"])
            .arg(self.base.join("home"))
            .args(extra)
            .output()
            .unwrap()
    }
    fn install(&self) {
        let output = self.setup("install", &[]);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    /// A repository holding a large `big.rs` and a small `small.rs`.
    fn repo(&self, name: &str) -> Repo<'_> {
        let dir = self.base.join(name);
        fs::create_dir_all(&dir).unwrap();
        let repo = Repo { machine: self, dir };
        repo.ok(&["init", "-q", "-b", "main"]);
        repo.write("big.rs", 900);
        repo.write("small.rs", 10);
        repo.ok(&["add", "-A"]);
        repo.ok(&["commit", "-qnm", "start"]);
        repo
    }
    /// A directory owned by another tool, shaped like a chain script hooks link to. It
    /// logs next to itself, so its work can be seen from a test.
    fn other_tools_hooks(&self) -> (PathBuf, String) {
        let dir = self.base.join("other-tool");
        fs::create_dir_all(&dir).unwrap();
        let chain = dir.join("_chain");
        let log = dir.join("log");
        let text = format!(
            "#!/bin/sh\necho \"ran $(basename \"$0\")\" >> '{}'\nexit 0\n",
            log.display()
        );
        fs::write(&chain, &text).unwrap();
        fs::set_permissions(&chain, fs::Permissions::from_mode(0o755)).unwrap();
        for hook in ["pre-commit", "commit-msg"] {
            symlink("_chain", dir.join(hook)).unwrap();
        }
        self.config(&["core.hooksPath", dir.to_str().unwrap()]);
        (chain, text)
    }
}

struct Repo<'a> {
    machine: &'a Machine,
    dir: PathBuf,
}

impl Repo<'_> {
    fn git(&self, args: &[&str]) -> Output {
        self.machine.git(&self.dir, args)
    }
    fn ok(&self, args: &[&str]) {
        let output = self.git(args);
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    fn write(&self, name: &str, lines: usize) {
        fs::write(self.dir.join(name), "x\n".repeat(lines)).unwrap();
    }
    fn commit_staged(&self) -> Result<(), String> {
        let output = self.git(&["commit", "-qm", "change"]);
        if output.status.success() {
            Ok(())
        } else {
            Err(String::from_utf8_lossy(&output.stderr).into_owned())
        }
    }
    /// Stages everything and tries to commit; `Ok` or the hook's words.
    fn commit(&self) -> Result<(), String> {
        self.ok(&["add", "-A"]);
        self.commit_staged()
    }
}

#[test]
fn every_repository_is_covered_without_naming_any() {
    let machine = Machine::new();
    let before = machine.repo("before");
    machine.install();
    let after = machine.repo("after");
    for repo in [&before, &after] {
        repo.write("big.rs", 901);
        let refused = repo.commit().unwrap_err();
        assert!(
            refused.contains("big.rs: grew from 900 to 901"),
            "{refused}"
        );
    }
    let head = before.git(&["rev-parse", "HEAD"]).stdout;
    assert!(before.commit().is_err());
    assert_eq!(before.git(&["rev-parse", "HEAD"]).stdout, head);
}

#[test]
fn naming_a_repository_is_refused_with_the_way_to_turn_one_off() {
    let machine = Machine::new();
    let output = machine.setup("install", &["--repo", "/tmp"]);
    assert!(!output.status.success());
    let words = String::from_utf8_lossy(&output.stderr);
    assert!(words.contains("vibeguard.sizeLimit false"), "{words}");
}

#[test]
fn one_repository_can_be_turned_off() {
    let machine = Machine::new();
    machine.install();
    let repo = machine.repo("theirs");
    repo.ok(&["config", "vibeguard.sizeLimit", "false"]);
    repo.write("big.rs", 950);
    repo.commit().unwrap();
}

#[test]
fn a_repositorys_own_hooks_still_run_when_nothing_owned_the_hooks_path() {
    let machine = Machine::new();
    machine.install();
    assert!(machine.hooks_path().is_some());
    let repo = machine.repo("own");
    let marker = repo.dir.join(".git/ran");
    for hook in ["pre-commit", "post-commit"] {
        let path = repo.dir.join(".git/hooks").join(hook);
        fs::write(
            &path,
            format!("#!/bin/sh\necho {hook} >> '{}'\n", marker.display()),
        )
        .unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    }
    repo.write("small.rs", 11);
    repo.commit().unwrap();
    assert_eq!(
        fs::read_to_string(&marker).unwrap(),
        "pre-commit\npost-commit\n"
    );
    repo.write("big.rs", 950);
    assert!(repo.commit().unwrap_err().contains("grew"));
}

#[test]
fn uninstall_gives_the_machine_back_when_nothing_owned_the_hooks_path() {
    let machine = Machine::new();
    machine.install();
    assert!(machine.setup("status", &[]).status.success());
    assert!(machine.setup("uninstall", &[]).status.success());
    assert_eq!(machine.hooks_path(), None);
    assert!(!machine.base.join("home/.vibeguard/git-hooks").exists());
    assert!(!machine.setup("status", &[]).status.success());
    let repo = machine.repo("free");
    repo.write("big.rs", 950);
    repo.commit().unwrap();
}

#[test]
fn another_tools_hooks_keep_working_and_get_back_their_exact_text() {
    let machine = Machine::new();
    let (chain, text) = machine.other_tools_hooks();
    machine.install();
    machine.install();
    let edited = fs::read_to_string(&chain).unwrap();
    assert_eq!(
        edited.matches("VibeGuard line limit >>>").count(),
        1,
        "{edited}"
    );
    let link = fs::symlink_metadata(chain.with_file_name("pre-commit")).unwrap();
    assert!(link.file_type().is_symlink(), "the owner's layout stays");
    assert!(machine.setup("status", &[]).status.success());
    let repo = machine.repo("chained");
    repo.write("big.rs", 950);
    assert!(repo.commit().unwrap_err().contains("grew"));
    repo.write("big.rs", 900);
    repo.write("small.rs", 11);
    repo.commit().unwrap();
    let ran = fs::read_to_string(chain.with_file_name("log")).unwrap();
    assert!(
        ran.contains("ran pre-commit") && ran.contains("ran commit-msg"),
        "{ran}"
    );
    assert!(machine.setup("uninstall", &[]).status.success());
    assert_eq!(fs::read_to_string(&chain).unwrap(), text);
    assert!(machine.hooks_path().is_some(), "not ours to unset");
}

#[test]
fn a_hook_vibeguard_cant_edit_is_left_alone() {
    let machine = Machine::new();
    let dir = machine.base.join("other-tool");
    fs::create_dir_all(&dir).unwrap();
    machine.config(&["core.hooksPath", dir.to_str().unwrap()]);
    let hook = dir.join("pre-commit");
    let text = "#!/usr/bin/env python3\nprint('mine')\n";
    fs::write(&hook, text).unwrap();
    let refused = machine.setup("install", &[]);
    assert!(!refused.status.success());
    assert!(String::from_utf8_lossy(&refused.stderr).contains("not a shell script"));
    assert_eq!(fs::read_to_string(&hook).unwrap(), text);
}

#[test]
fn a_missing_hook_in_another_tools_directory_is_added_and_removed() {
    let machine = Machine::new();
    let dir = machine.base.join("other-tool");
    fs::create_dir_all(&dir).unwrap();
    machine.config(&["core.hooksPath", dir.to_str().unwrap()]);
    machine.install();
    assert!(dir.join("pre-commit").exists());
    let repo = machine.repo("a");
    repo.write("big.rs", 950);
    assert!(repo.commit().is_err());
    assert!(machine.setup("uninstall", &[]).status.success());
    assert!(!dir.join("pre-commit").exists());
}

#[test]
fn losing_the_binary_or_failing_inside_doesnt_stop_commits() {
    let machine = Machine::new();
    machine.install();
    let repo = machine.repo("b");
    fs::remove_file(machine.base.join("home/.vibeguard/bin/vibeguard-runtime")).unwrap();
    repo.write("big.rs", 950);
    repo.commit().expect("no binary, no check");

    let outside = machine.base.join("not-a-repository");
    fs::create_dir_all(&outside).unwrap();
    let output = Command::new(BIN)
        .current_dir(&outside)
        .env("GIT_CEILING_DIRECTORIES", &machine.base)
        .arg("pre-commit")
        .output()
        .unwrap();
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("not checked"));
}

#[test]
fn a_dry_run_changes_nothing() {
    let machine = Machine::new();
    let output = machine.setup("install", &["--dry-run"]);
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("set_global_git_config"));
    assert_eq!(machine.hooks_path(), None);
    assert!(!machine.base.join("home").exists());
}

#[test]
fn a_large_file_can_only_get_shorter() {
    let machine = Machine::new();
    machine.install();
    let repo = machine.repo("r");
    repo.write("big.rs", 850);
    repo.commit().unwrap();
    repo.write("small.rs", 11);
    repo.commit().unwrap();
    repo.write("big.rs", 851);
    let refused = repo.commit().unwrap_err();
    assert!(refused.contains("grew from 850 to 851"), "{refused}");
}

#[test]
fn only_source_files_past_the_limit_count() {
    let machine = Machine::new();
    machine.install();
    let repo = machine.repo("r");
    repo.write("small.rs", 800);
    repo.write("notes.md", 5000);
    repo.commit().unwrap();
    repo.write("small.rs", 801);
    assert!(repo.commit().unwrap_err().contains("small.rs: 801 lines"));
}

#[test]
fn a_new_file_past_the_limit_is_refused_even_as_the_first_commit() {
    let machine = Machine::new();
    machine.install();
    let dir = machine.base.join("fresh");
    fs::create_dir_all(&dir).unwrap();
    let repo = Repo {
        machine: &machine,
        dir,
    };
    repo.ok(&["init", "-q", "-b", "main"]);
    repo.write("new.rs", 801);
    assert!(repo.commit().unwrap_err().contains("new.rs: 801 lines"));
    repo.write("new.rs", 800);
    repo.commit().unwrap();
}

#[test]
fn only_what_is_staged_counts() {
    let machine = Machine::new();
    machine.install();
    let repo = machine.repo("r");
    repo.write("small.rs", 11);
    repo.ok(&["add", "small.rs"]);
    repo.write("big.rs", 950);
    repo.commit_staged()
        .expect("the unstaged growth isn't in this commit");
    repo.ok(&["add", "big.rs"]);
    repo.write("big.rs", 900);
    let refused = repo.commit_staged().unwrap_err();
    assert!(refused.contains("grew from 900 to 950"), "{refused}");
}

#[test]
fn commit_all_is_checked() {
    let machine = Machine::new();
    machine.install();
    let repo = machine.repo("r");
    repo.write("big.rs", 950);
    assert!(!repo.git(&["commit", "-qam", "all"]).status.success());
}

#[test]
fn a_rename_is_compared_with_its_old_name() {
    let machine = Machine::new();
    machine.install();
    let repo = machine.repo("r");
    repo.ok(&["mv", "big.rs", "moved.rs"]);
    repo.commit().expect("moving a large file isn't growing it");
    repo.ok(&["mv", "moved.rs", "again.rs"]);
    repo.write("again.rs", 905);
    let refused = repo.commit().unwrap_err();
    assert!(refused.contains("grew from 900 to 905"), "{refused}");
}

#[test]
fn concluding_a_merge_accepts_what_the_other_side_already_had() {
    let machine = Machine::new();
    machine.install();
    let repo = machine.repo("r");
    repo.write("c.txt", 1);
    repo.commit().unwrap();
    repo.ok(&["switch", "-qc", "side"]);
    repo.write("big.rs", 950);
    fs::write(repo.dir.join("c.txt"), "side\n").unwrap();
    repo.ok(&["add", "-A"]);
    repo.ok(&["commit", "-qnm", "side, past the hook"]);
    repo.ok(&["switch", "-q", "main"]);
    fs::write(repo.dir.join("c.txt"), "main\n").unwrap();
    repo.commit().unwrap();
    assert!(
        !repo.git(&["merge", "-q", "side"]).status.success(),
        "conflict"
    );
    fs::write(repo.dir.join("c.txt"), "both\n").unwrap();
    repo.commit()
        .expect("big.rs is the other side's, not this commit's");
    // Adding to it while concluding a merge is this commit's.
    repo.ok(&["switch", "-qc", "side2", "HEAD~1"]);
    fs::write(repo.dir.join("c.txt"), "two\n").unwrap();
    repo.commit().unwrap();
    repo.ok(&["switch", "-q", "main"]);
    assert!(
        !repo.git(&["merge", "-q", "side2"]).status.success(),
        "conflict"
    );
    fs::write(repo.dir.join("c.txt"), "both\n").unwrap();
    repo.write("big.rs", 951);
    assert!(repo.commit().unwrap_err().contains("grew from 950 to 951"));
}

#[test]
fn a_linked_worktree_is_guarded_too() {
    let machine = Machine::new();
    machine.install();
    let repo = machine.repo("r");
    let other = machine.base.join("other");
    repo.ok(&["worktree", "add", "-q", "-b", "w", other.to_str().unwrap()]);
    let linked = Repo {
        machine: &machine,
        dir: other,
    };
    linked.write("big.rs", 950);
    let refused = linked.commit().unwrap_err();
    assert!(refused.contains("grew from 900 to 950"), "{refused}");
}
