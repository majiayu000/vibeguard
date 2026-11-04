//! The line limit at commit time, driven through a real `git commit` with the hook
//! installed the way a person would install it.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

const BIN: &str = env!("CARGO_BIN_EXE_vibeguard-runtime");
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Repo {
    base: PathBuf,
    dir: PathBuf,
}

impl Drop for Repo {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.base);
    }
}

fn git_at(dir: &Path, args: &[&str]) -> Output {
    Command::new("git")
        .current_dir(dir)
        // This machine's hooks directory must not decide the outcome of a test.
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .args(args)
        .output()
        .unwrap()
}

impl Repo {
    fn bare() -> Self {
        let base = std::env::temp_dir().join(format!(
            "vibeguard-pre-commit-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let dir = base.join("repo");
        fs::create_dir_all(&dir).unwrap();
        let repo = Repo {
            dir: dir.canonicalize().unwrap(),
            base: base.canonicalize().unwrap(),
        };
        repo.ok(&["init", "-q", "-b", "main"]);
        repo.ok(&["config", "user.email", "t@example.com"]);
        repo.ok(&["config", "user.name", "t"]);
        repo
    }
    /// A repository holding a large `big.rs`, with the hook installed.
    fn new() -> Self {
        let repo = Self::bare();
        repo.write("big.rs", 900);
        repo.write("small.rs", 10);
        repo.ok(&["add", "-A"]);
        repo.ok(&["commit", "-qm", "start"]);
        repo.setup("install");
        repo
    }
    fn setup(&self, action: &str) -> Output {
        let home = self.base.join("home");
        Command::new(BIN)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .args([action, "git-size", "--home"])
            .arg(&home)
            .arg("--repo")
            .arg(&self.dir)
            .output()
            .unwrap()
    }
    fn git(&self, args: &[&str]) -> Output {
        git_at(&self.dir, args)
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
    /// Stages everything and tries to commit; `Ok` or the hook's words.
    fn commit(&self) -> Result<(), String> {
        self.ok(&["add", "-A"]);
        commit_at(&self.dir)
    }
}

fn commit_at(dir: &Path) -> Result<(), String> {
    let output = git_at(dir, &["commit", "-qm", "change"]);
    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).into_owned())
    }
}

#[test]
fn growth_past_the_limit_is_refused_and_nothing_is_committed() {
    let repo = Repo::new();
    let head = repo.git(&["rev-parse", "HEAD"]).stdout;
    repo.write("big.rs", 901);
    let refused = repo.commit().unwrap_err();
    assert!(
        refused.contains("big.rs: grew from 900 to 901"),
        "{refused}"
    );
    assert_eq!(repo.git(&["rev-parse", "HEAD"]).stdout, head);
}

#[test]
fn a_large_file_can_only_get_shorter() {
    let repo = Repo::new();
    repo.write("big.rs", 850);
    repo.commit().unwrap();
    repo.write("big.rs", 850);
    repo.write("small.rs", 11);
    repo.commit().unwrap();
    repo.write("big.rs", 851);
    let refused = repo.commit().unwrap_err();
    assert!(refused.contains("grew from 850 to 851"), "{refused}");
}

#[test]
fn only_source_files_past_the_limit_count() {
    let repo = Repo::new();
    repo.write("small.rs", 800);
    repo.write("notes.md", 5000);
    repo.commit().unwrap();
    repo.write("small.rs", 801);
    assert!(repo.commit().unwrap_err().contains("small.rs: 801 lines"));
}

#[test]
fn a_new_file_past_the_limit_is_refused_even_as_the_first_commit() {
    let repo = Repo::bare();
    repo.setup("install");
    repo.write("new.rs", 801);
    assert!(repo.commit().unwrap_err().contains("new.rs: 801 lines"));
    repo.write("new.rs", 800);
    repo.commit().unwrap();
}

#[test]
fn only_what_is_staged_counts() {
    let repo = Repo::new();
    repo.write("small.rs", 11);
    repo.ok(&["add", "small.rs"]);
    repo.write("big.rs", 950);
    commit_at(&repo.dir).expect("the unstaged growth isn't in this commit");
    repo.ok(&["add", "big.rs"]);
    repo.write("big.rs", 900);
    let refused = commit_at(&repo.dir).unwrap_err();
    assert!(refused.contains("grew from 900 to 950"), "{refused}");
}

#[test]
fn commit_all_is_checked() {
    let repo = Repo::new();
    repo.write("big.rs", 950);
    let output = repo.git(&["commit", "-qam", "all"]);
    assert!(!output.status.success());
}

#[test]
fn a_rename_is_compared_with_its_old_name() {
    let repo = Repo::new();
    repo.ok(&["mv", "big.rs", "moved.rs"]);
    repo.commit().expect("moving a large file isn't growing it");
    repo.ok(&["mv", "moved.rs", "again.rs"]);
    repo.write("again.rs", 905);
    let refused = repo.commit().unwrap_err();
    assert!(refused.contains("grew from 900 to 905"), "{refused}");
}

#[test]
fn concluding_a_merge_accepts_what_the_other_side_already_had() {
    let repo = Repo::new();
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
    let repo = Repo::new();
    let other = repo.base.join("other");
    repo.ok(&["worktree", "add", "-q", "-b", "w", other.to_str().unwrap()]);
    fs::write(other.join("big.rs"), "x\n".repeat(950)).unwrap();
    assert!(git_at(&other, &["add", "-A"]).status.success());
    let refused = commit_at(&other).unwrap_err();
    assert!(refused.contains("grew from 900 to 950"), "{refused}");
}

#[test]
fn another_tools_hooks_directory_is_reported_and_can_chain_to_ours() {
    let repo = Repo::new();
    let elsewhere = repo.base.join("hooks");
    fs::create_dir_all(&elsewhere).unwrap();
    let chain = elsewhere.join("pre-commit");
    fs::write(
        &chain,
        "#!/bin/sh\nown=\"$(git rev-parse --git-common-dir)/hooks/pre-commit\"\n[ -x \"$own\" ] && exec \"$own\"\nexit 0\n",
    )
    .unwrap();
    assert!(
        Command::new("chmod")
            .arg("+x")
            .arg(&chain)
            .status()
            .unwrap()
            .success()
    );
    repo.ok(&["config", "core.hooksPath", elsewhere.to_str().unwrap()]);
    let status = String::from_utf8_lossy(&repo.setup("status").stdout).into_owned();
    assert!(status.contains("hooks_path_override"), "{status}");
    assert!(status.contains(chain.to_str().unwrap()), "{status}");
    repo.write("big.rs", 950);
    assert!(repo.commit().unwrap_err().contains("grew from 900 to 950"));
}

#[test]
fn a_users_hook_is_left_alone_and_only_ours_is_removed() {
    let repo = Repo::bare();
    let hook = repo.dir.join(".git/hooks/pre-commit");
    fs::write(&hook, "#!/bin/sh\necho mine\n").unwrap();
    let refused = repo.setup("install");
    assert!(!refused.status.success());
    assert!(String::from_utf8_lossy(&refused.stderr).contains("user-managed"));
    assert_eq!(fs::read_to_string(&hook).unwrap(), "#!/bin/sh\necho mine\n");
    fs::remove_file(&hook).unwrap();
    assert!(repo.setup("install").status.success());
    let text = fs::read_to_string(&hook).unwrap();
    assert!(text.contains("pre-commit"), "{text}");
    assert!(
        !repo.dir.join(".git/hooks/pre-push").exists(),
        "push rules stay separate"
    );
    assert!(repo.setup("status").status.success());
    assert!(repo.setup("uninstall").status.success());
    assert!(!hook.exists());
}
