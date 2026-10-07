use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

const BIN: &str = env!("CARGO_BIN_EXE_vibeguard-runtime");
const NULL_FILE: &str = if cfg!(windows) { "NUL" } else { "/dev/null" };
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "vibeguard-git-inspection-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.0) {
            if std::thread::panicking() {
                eprintln!("test cleanup failed: {error}");
            } else {
                panic!("test cleanup failed: {error}");
            }
        }
    }
}

fn command(program: &str, repo: &Path) -> Command {
    let mut command = Command::new(program);
    command
        .current_dir(repo)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", NULL_FILE)
        .env_remove("GIT_GRAFT_FILE")
        .env("GIT_ALLOW_PROTOCOL", "file");
    command
}

fn git_command(repo: &Path) -> Command {
    let mut command = command("git", repo);
    command.args([
        "-c",
        "commit.gpgsign=false",
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.invalid",
    ]);
    command
}

fn success(output: &Output) {
    assert!(
        output.status.success(),
        "stdout={}\nstderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn git(repo: &Path, args: &[&str]) -> String {
    let output = git_command(repo).args(args).output().unwrap();
    success(&output);
    String::from_utf8(output.stdout).unwrap().trim().to_string()
}

fn pre_push(command: &mut Command, input: &str) -> Output {
    let mut child = command
        .arg("pre-push")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

#[test]
fn object_types_ignore_replace_refs() {
    let temp = Temp::new();
    git(&temp.0, &["init", "-q"]);
    fs::write(temp.0.join("value"), "base").unwrap();
    git(&temp.0, &["add", "value"]);
    git(&temp.0, &["commit", "-qm", "base"]);
    let commit = git(&temp.0, &["rev-parse", "HEAD"]);
    let blob = git(&temp.0, &["rev-parse", "HEAD:value"]);
    git(&temp.0, &["replace", "-f", &blob, &commit]);
    assert_eq!(git(&temp.0, &["cat-file", "-t", &blob]), "commit");

    let zero = "0".repeat(commit.len());
    for (destination, remote) in [
        ("refs/heads/main", zero.as_str()),
        ("refs/custom/main", commit.as_str()),
    ] {
        let record = format!("HEAD {blob} {destination} {remote}\n");
        let output = pre_push(&mut command(BIN, &temp.0), &record);
        assert_eq!(output.status.code(), Some(1), "{output:?}");
        assert!(String::from_utf8_lossy(&output.stderr).contains("commits"));
    }
}

#[test]
fn ancestry_ignores_default_and_external_grafts_in_worktrees_and_bare_repos() {
    for bare in [false, true] {
        let temp = Temp::new();
        git(
            &temp.0,
            if bare {
                &["init", "--bare", "-q"]
            } else {
                &["init", "-q"]
            },
        );
        let tree = git(&temp.0, &["mktree"]);
        let base = git(&temp.0, &["commit-tree", &tree, "-m", "base"]);
        let next = git(&temp.0, &["commit-tree", &tree, "-p", &base, "-m", "next"]);
        let divergent = git(&temp.0, &["commit-tree", &tree, "-m", "divergent"]);
        let zero = "0".repeat(base.len());
        for external in [false, true] {
            let grafts = if external {
                temp.0.join("external-grafts")
            } else {
                temp.0
                    .join(git(&temp.0, &["rev-parse", "--git-path", "info/grafts"]))
            };
            fs::write(&grafts, format!("{divergent} {next}\n")).unwrap();
            let with_grafts = |program| {
                let mut command = command(program, &temp.0);
                if external {
                    command.env("GIT_GRAFT_FILE", &grafts);
                }
                command
            };
            // Even these raw-object flags still honor Git's legacy grafts.
            success(
                &with_grafts("git")
                    .args([
                        "--no-replace-objects",
                        "--no-lazy-fetch",
                        "merge-base",
                        "--is-ancestor",
                        &next,
                        &divergent,
                    ])
                    .output()
                    .unwrap(),
            );
            for (local, remote, expected) in [
                (&next, &base, 0),
                (&divergent, &zero, 0),
                (&divergent, &next, 1),
            ] {
                let input = format!("HEAD {local} refs/heads/main {remote}\n");
                let output = pre_push(&mut with_grafts(BIN), &input);
                assert_eq!(
                    output.status.code(),
                    Some(expected),
                    "bare={bare}, external={external}: {output:?}"
                );
                if expected == 1 {
                    assert!(String::from_utf8_lossy(&output.stderr).contains("non-fast-forward"));
                }
            }
            fs::remove_file(grafts).unwrap();
        }
    }
}

#[cfg(unix)]
#[test]
fn installed_hook_rejects_local_history_overlays_during_a_local_push() {
    let temp = Temp::new();
    let repo = temp.0.join("repo");
    let remote = temp.0.join("remote.git");
    fs::create_dir(&repo).unwrap();
    fs::create_dir(&remote).unwrap();
    git(&repo, &["init", "-q"]);
    git(&repo, &["config", "core.hooksPath", ".git/hooks"]);
    git(&remote, &["init", "--bare", "-q"]);
    git(&repo, &["commit", "--allow-empty", "-qm", "base"]);
    let base = git(&repo, &["rev-parse", "HEAD"]);
    success(
        &command(BIN, &repo)
            .args([
                "install",
                "git",
                "--home",
                temp.0.to_str().unwrap(),
                "--repo",
                repo.to_str().unwrap(),
            ])
            .output()
            .unwrap(),
    );
    let remote_path = remote.to_str().unwrap();
    git(&repo, &["push", remote_path, "HEAD:refs/heads/main"]);
    git(&repo, &["commit", "--allow-empty", "-qm", "next"]);
    let next = git(&repo, &["rev-parse", "HEAD"]);
    git(&repo, &["push", remote_path, "HEAD:refs/heads/main"]);

    git(&repo, &["checkout", "--detach", &base]);
    git(&repo, &["commit", "--allow-empty", "-qm", "divergent"]);
    let divergent = git(&repo, &["rev-parse", "HEAD"]);
    let tree = git(&repo, &["rev-parse", "HEAD^{tree}"]);
    let replacement = git(
        &repo,
        &["commit-tree", &tree, "-p", &next, "-m", "replacement"],
    );
    for overlay in ["replace", "grafts", "GIT_GRAFT_FILE"] {
        let grafts = if overlay == "grafts" {
            repo.join(".git/info/grafts")
        } else {
            temp.0.join("external-grafts")
        };
        let mut control = git_command(&repo);
        let mut push = git_command(&repo);
        if overlay == "replace" {
            git(&repo, &["replace", &divergent, &replacement]);
        } else {
            fs::write(&grafts, format!("{divergent} {next}\n")).unwrap();
            if overlay == "GIT_GRAFT_FILE" {
                control.env("GIT_GRAFT_FILE", &grafts);
                push.env("GIT_GRAFT_FILE", &grafts);
            }
        }
        // Git's local view falsely treats this divergent commit as a descendant.
        success(
            &control
                .args(["merge-base", "--is-ancestor", &next, &divergent])
                .output()
                .unwrap(),
        );
        let output = push
            .args(["push", "--force", remote_path, "HEAD:refs/heads/main"])
            .output()
            .unwrap();
        assert!(!output.status.success(), "{overlay}: {output:?}");
        assert!(
            String::from_utf8_lossy(&output.stderr)
                .contains("VibeGuard: non-fast-forward push is blocked"),
            "{overlay}: {output:?}"
        );
        assert_eq!(git(&remote, &["rev-parse", "refs/heads/main"]), next);
        if overlay == "replace" {
            git(&repo, &["replace", "-d", &divergent]);
        } else {
            fs::remove_file(grafts).unwrap();
        }
    }
}

#[cfg(unix)]
#[test]
fn missing_promisor_object_does_not_start_a_fetch() {
    let temp = Temp::new();
    let repo = temp.0.join("repo");
    let remote = temp.0.join("remote.git");
    fs::create_dir(&repo).unwrap();
    fs::create_dir(&remote).unwrap();
    git(&repo, &["init", "-q"]);
    git(&remote, &["init", "--bare", "-q"]);
    let marker = temp.0.join("fetch-attempt");
    let upload_pack = temp.0.join("upload-pack");
    let quote = |path: &Path| format!("'{}'", path.to_str().unwrap().replace('\'', "'\\''"));
    fs::write(
        &upload_pack,
        format!("#!/bin/sh\nprintf fetched > {}\nexit 1\n", quote(&marker)),
    )
    .unwrap();
    git(
        &repo,
        &["config", "remote.origin.url", remote.to_str().unwrap()],
    );
    git(&repo, &["config", "remote.origin.promisor", "true"]);
    git(
        &repo,
        &[
            "config",
            "remote.origin.uploadpack",
            &format!("sh {}", quote(&upload_pack)),
        ],
    );
    let missing = "1".repeat(40);
    // Verify the fixture really attempts lazy fetch with ordinary cat-file.
    let control = git_command(&repo)
        .args(["cat-file", "-t", &missing])
        .output()
        .unwrap();
    assert!(!control.status.success());
    assert!(marker.exists());
    fs::remove_file(&marker).unwrap();

    let record = format!("HEAD {missing} refs/heads/main {}\n", "0".repeat(40));
    let output = pre_push(&mut command(BIN, &repo), &record);
    assert_eq!(output.status.code(), Some(2), "{output:?}");
    assert!(String::from_utf8_lossy(&output.stderr).contains("could not inspect Git object"));
    assert!(!marker.exists(), "Git inspection attempted to fetch");
}

#[cfg(unix)]
#[test]
fn unsupported_git_options_report_the_minimum_version() {
    use std::os::unix::fs::PermissionsExt;

    let temp = Temp::new();
    let git = temp.0.join("git");
    fs::write(&git, "#!/bin/sh\nexit 129\n").unwrap();
    fs::set_permissions(&git, fs::Permissions::from_mode(0o755)).unwrap();
    let record = format!(
        "HEAD {} refs/heads/main {}\n",
        "1".repeat(40),
        "0".repeat(40)
    );
    let output = pre_push(command(BIN, &temp.0).env("PATH", &temp.0), &record);
    assert_eq!(output.status.code(), Some(2), "{output:?}");
    assert!(String::from_utf8_lossy(&output.stderr).contains("Git 2.45 or newer"));
}

#[cfg(unix)]
#[test]
fn unsupported_git_is_rejected_before_setup_but_can_uninstall() {
    use std::os::unix::fs::PermissionsExt;

    let real_git = std::env::split_paths(&std::env::var_os("PATH").unwrap())
        .map(|path| path.join("git"))
        .find(|path| path.is_file())
        .unwrap()
        .canonicalize()
        .unwrap();
    let temp = Temp::new();
    let repo = temp.0.join("repo");
    fs::create_dir(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    git(&repo, &["config", "core.hooksPath", ".git/hooks"]);
    let hook = repo.join(".git/hooks/pre-push");
    let fake_bin = temp.0.join("old-git");
    fs::create_dir(&fake_bin).unwrap();
    let fake_git = fake_bin.join("git");
    fs::write(
        &fake_git,
        "#!/bin/sh\ncase \" $* \" in *' --no-lazy-fetch '*) exit 129;; esac\nexec \"$VIBEGUARD_TEST_REAL_GIT\" \"$@\"\n",
    )
    .unwrap();
    fs::set_permissions(&fake_git, fs::Permissions::from_mode(0o755)).unwrap();
    let home = temp.0.join("home");
    for (action, dry_run) in [("install", false), ("install", true), ("status", false)] {
        let mut request = command(BIN, &repo);
        request
            .env("PATH", &fake_bin)
            .env("VIBEGUARD_TEST_REAL_GIT", &real_git)
            .args([action, "git", "--home"])
            .arg(&home)
            .arg("--repo")
            .arg(&repo);
        if dry_run {
            request.arg("--dry-run");
        }
        let output = request.output().unwrap();
        assert_eq!(
            output.status.code(),
            Some(2),
            "{action} dry={dry_run}: {output:?}"
        );
        assert!(String::from_utf8_lossy(&output.stderr).contains("Git 2.45 or newer"));
        assert!(!home.exists(), "unsupported Git created setup files");
        assert!(!hook.exists(), "unsupported Git installed a hook");
    }

    success(
        &command(BIN, &repo)
            .args(["install", "git", "--home"])
            .arg(&home)
            .arg("--repo")
            .arg(&repo)
            .output()
            .unwrap(),
    );
    assert!(hook.exists());
    success(
        &command(BIN, &repo)
            .env("PATH", &fake_bin)
            .env("VIBEGUARD_TEST_REAL_GIT", &real_git)
            .args(["uninstall", "git", "--home"])
            .arg(&home)
            .arg("--repo")
            .arg(&repo)
            .output()
            .unwrap(),
    );
    assert!(!hook.exists(), "old Git must still allow removing the hook");
}
