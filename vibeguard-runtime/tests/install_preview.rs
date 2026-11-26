//! For every installable host, `install --dry-run` names exactly the files the real install then writes.
#![cfg(unix)]

use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

const BIN: &str = env!("CARGO_BIN_EXE_vibeguard-runtime");
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "vibeguard-preview-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        // Install reports canonical paths (macOS /var is /private/var); compare like with like.
        Self(fs::canonicalize(path).unwrap())
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn invoke(root: &Path, args: &[&str]) -> Output {
    let output = Command::new(BIN)
        .current_dir(root)
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .env_remove("GIT_CONFIG_NOSYSTEM")
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{args:?}\nstdout={}\nstderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    output
}

/// Every file under `root` with its mode and bytes.
fn snapshot(root: &Path) -> BTreeMap<PathBuf, (u32, Vec<u8>)> {
    let mut files = BTreeMap::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        for entry in fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            let metadata = fs::symlink_metadata(&path).unwrap();
            if metadata.is_dir() {
                pending.push(path);
            } else {
                let bytes = if metadata.is_file() {
                    fs::read(&path).unwrap()
                } else {
                    Vec::new()
                };
                files.insert(path, (metadata.permissions().mode(), bytes));
            }
        }
    }
    files
}

/// The paths a preview says install changes, and the setup locks it says install acquires.
/// `core.hooksPath` is a setting; with an explicit `--home` it lives in that home's `.gitconfig`.
fn previewed(output: &Output, home: &Path) -> (BTreeSet<PathBuf>, BTreeSet<PathBuf>) {
    let plan: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(plan["dry_run"], true);
    let changes = plan["changes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|change| match change["path"].as_str().unwrap() {
            "core.hooksPath" => home.join(".gitconfig"),
            path => PathBuf::from(path),
        })
        .collect();
    let locks = plan["setup_locks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|lock| PathBuf::from(lock.as_str().unwrap()))
        .collect();
    (changes, locks)
}

/// Runs the preview, then the install, and requires the files that changed to be the previewed ones
/// (setup locks may also appear). A reinstall then previews and writes nothing beyond the locks.
fn assert_preview_matches(root: &Path, home: &Path, args: &[&str]) {
    for round in ["first install", "reinstall"] {
        let before = snapshot(root);
        let preview = invoke(root, &[args, &["--dry-run"]].concat());
        assert_eq!(
            snapshot(root),
            before,
            "{args:?} {round}: the preview wrote files"
        );
        let (changes, locks) = previewed(&preview, home);
        invoke(root, args);
        let after = snapshot(root);
        let wrote: BTreeSet<PathBuf> = before
            .keys()
            .chain(after.keys())
            .filter(|path| before.get(*path) != after.get(*path))
            .filter(|path| !locks.contains(*path))
            .cloned()
            .collect();
        // A previewed directory (git-size's hooks directory) covers the files written inside it.
        let unpreviewed: Vec<_> = wrote
            .iter()
            .filter(|path| !changes.iter().any(|change| path.starts_with(change)))
            .collect();
        let unwritten: Vec<_> = changes
            .iter()
            .filter(|change| !wrote.iter().any(|path| path.starts_with(change)))
            .collect();
        assert!(
            unpreviewed.is_empty() && unwritten.is_empty(),
            "{args:?} {round}: written but not previewed {unpreviewed:?}; previewed but not written {unwritten:?}"
        );
    }
}

#[test]
fn native_host_previews_match_what_install_writes() {
    for host in ["claude", "codex", "grok"] {
        let temp = Temp::new();
        let home = temp.0.join("home");
        let dir = home.join(format!(".{host}"));
        // Existing user settings and an old owned block, so install edits files as well as creating them.
        let (config, instructions) = match host {
            "codex" => ("hooks.json", "AGENTS.md"),
            "grok" => ("hooks/vibeguard.json", "rules/vibeguard.md"),
            _ => ("settings.json", "CLAUDE.md"),
        };
        for (file, text) in [
            (config, r#"{"user":7,"hooks":{}}"#),
            (
                instructions,
                "user note\n<!-- vibeguard-core:start -->\nold\n<!-- vibeguard-core:end -->\n",
            ),
        ] {
            fs::create_dir_all(dir.join(file).parent().unwrap()).unwrap();
            fs::write(dir.join(file), text).unwrap();
        }
        if host == "codex" {
            fs::write(
                dir.join("config.toml"),
                "model = 'user-model'\n[features]\nhooks = false\n",
            )
            .unwrap();
        }
        assert_preview_matches(
            &temp.0,
            &home,
            &["install", host, "--home", home.to_str().unwrap()],
        );
    }
}

#[test]
fn git_previews_match_what_install_writes() {
    let temp = Temp::new();
    let home = temp.0.join("home");
    fs::create_dir(&home).unwrap();
    let repo = temp.0.join("repo");
    fs::create_dir(&repo).unwrap();
    let init = Command::new("git")
        .args(["init", "-q"])
        .arg(&repo)
        .env("HOME", &home)
        .status()
        .unwrap();
    assert!(init.success());
    let (home_arg, repo_arg) = (home.to_str().unwrap(), repo.to_str().unwrap());
    assert_preview_matches(
        &temp.0,
        &home,
        &["install", "git", "--home", home_arg, "--repo", repo_arg],
    );
    assert_preview_matches(&temp.0, &home, &["install", "git-size", "--home", home_arg]);
}
