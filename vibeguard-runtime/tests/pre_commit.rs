//! The commit-time line limit, driven through a real `git commit` with the hook
//! installed for a temporary machine: its own home and global Git configuration.
#![cfg(unix)]

use serde_json::Value;
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
        fs::create_dir_all(base.join("home")).unwrap();
        let machine = Machine {
            base: base.canonicalize().unwrap(),
        };
        machine.config(&["user.email", "t@example.com"]);
        machine.config(&["user.name", "t"]);
        machine
    }
    /// Where Git keeps the global configuration of the home that `setup` names.
    fn gitconfig(&self) -> PathBuf {
        self.base.join("home/.gitconfig")
    }
    /// The system configuration of this machine: no file unless a test writes one.
    fn system_gitconfig(&self) -> PathBuf {
        self.base.join("system.gitconfig")
    }
    fn git(&self, dir: &Path, args: &[&str]) -> Output {
        Command::new("git")
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", self.gitconfig())
            .env("GIT_CONFIG_SYSTEM", self.system_gitconfig())
            .env_remove("GIT_CONFIG_NOSYSTEM")
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
            .env("GIT_CONFIG_SYSTEM", self.system_gitconfig())
            .env_remove("GIT_CONFIG_NOSYSTEM")
            .args([action, "git-size", "--home"])
            .arg(self.base.join("home"))
            .args(extra)
            .output()
            .unwrap()
    }
    /// `install git` and its companions: the pre-push hook of one repository.
    fn push_hook(&self, action: &str, repo: &Repo, extra: &[&str]) -> Output {
        Command::new(BIN)
            .current_dir(&self.base)
            .env("GIT_CONFIG_GLOBAL", self.gitconfig())
            .env("GIT_CONFIG_SYSTEM", self.system_gitconfig())
            .env_remove("GIT_CONFIG_NOSYSTEM")
            .args([action, "git", "--home"])
            .arg(self.base.join("home"))
            .arg("--repo")
            .arg(&repo.dir)
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
        let (chain, text) = self.other_tools_scripts();
        let dir = chain.parent().unwrap();
        self.config(&["core.hooksPath", dir.to_str().unwrap()]);
        (chain, text)
    }
    /// That directory before any configuration names it.
    fn other_tools_scripts(&self) -> (PathBuf, String) {
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
fn a_push_into_a_checked_out_branch_still_updates_its_work_tree() {
    let machine = Machine::new();
    machine.install();
    let source = machine.repo("source");
    let target = Repo {
        machine: &machine,
        dir: machine.base.join("target"),
    };
    let path = target.dir.to_str().unwrap();
    source.ok(&["clone", "-q", ".", path]);
    target.ok(&["config", "receive.denyCurrentBranch", "updateInstead"]);
    let push = |lines: usize| {
        source.write("small.rs", lines);
        source.commit().unwrap();
        source.git(&["push", "-q", path, "main"])
    };
    let arrived = || {
        let pushed = fs::read_to_string(target.dir.join("small.rs")).unwrap();
        let changes = target.git(&["status", "--porcelain"]).stdout;
        (pushed.lines().count(), String::from_utf8(changes).unwrap())
    };
    // Git updates the work tree itself, but not once a push-to-checkout hook exists.
    assert!(push(11).status.success());
    assert_eq!(arrived(), (11, String::new()));

    // The hook 2.3.0 put there only passed the call on. Installing again replaces it.
    let hooks = machine.base.join("home/.vibeguard/git-hooks");
    let passes_on = fs::read_to_string(hooks.join("post-update")).unwrap();
    fs::write(hooks.join("push-to-checkout"), passes_on).unwrap();
    machine.install();
    assert!(push(12).status.success());
    assert_eq!(arrived(), (12, String::new()));

    // Git's refusal when the work tree has changes of its own is kept.
    target.write("big.rs", 899);
    let refused = push(13);
    let words = String::from_utf8_lossy(&refused.stderr);
    assert!(!refused.status.success(), "{words}");
    assert!(words.contains("unstaged changes"), "{words}");
    assert_eq!(arrived(), (12, " M big.rs\n".to_owned()));
    target.write("big.rs", 900);

    // And a repository's own hook still decides instead.
    let own = target.dir.join(".git/hooks/push-to-checkout");
    let marker = machine.base.join("own-hook-ran");
    fs::write(
        &own,
        format!("#!/bin/sh\necho \"$1\" > '{}'\n", marker.display()),
    )
    .unwrap();
    fs::set_permissions(&own, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(push(14).status.success());
    let head = String::from_utf8(source.git(&["rev-parse", "HEAD"]).stdout).unwrap();
    assert_eq!(fs::read_to_string(&marker).unwrap(), head);
    assert_eq!(arrived().0, 12, "its hook left the work tree alone");
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
fn the_push_hook_stays_each_repositorys_own_when_nothing_owned_the_hooks_path() {
    let machine = Machine::new();
    let hook = |repo: &Repo| repo.dir.join(".git/hooks/pre-push");
    let before = machine.repo("before");
    assert!(machine.push_hook("install", &before, &[]).status.success());
    machine.install();
    let ours = machine.base.join("home/.vibeguard/git-hooks/pre-push");
    let passes_on = fs::read_to_string(&ours).unwrap();

    let status = machine.push_hook("status", &before, &[]);
    let report: Value = serde_json::from_slice(&status.stdout).unwrap();
    assert!(status.status.success(), "{report}");
    assert_eq!(report["hook"], hook(&before).to_str().unwrap());

    let after = machine.repo("after");
    for extra in [&["--dry-run"][..], &[]] {
        let output = machine.push_hook("install", &after, extra);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    assert_eq!(fs::read_to_string(&ours).unwrap(), passes_on);
    // The hook that was written is the one a push runs.
    let remote = machine.base.join("remote.git");
    let remote = remote.to_str().unwrap();
    after.ok(&["init", "-q", "--bare", remote]);
    after.ok(&["push", "-q", remote, "main"]);
    let refused = after.git(&["push", remote, ":main"]);
    let words = String::from_utf8_lossy(&refused.stderr);
    assert!(words.contains("deletion of remote ref"), "{words}");

    for repo in [&before, &after] {
        assert!(machine.push_hook("uninstall", repo, &[]).status.success());
        assert!(!hook(repo).exists());
        let status = machine.push_hook("status", repo, &[]);
        assert_eq!(status.status.code(), Some(1));
    }
    let mine = "#!/bin/sh\necho mine\n";
    fs::write(hook(&after), mine).unwrap();
    let refused = machine.push_hook("install", &after, &[]);
    assert_eq!(refused.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&refused.stderr).contains("user-managed"));
    assert_eq!(fs::read_to_string(hook(&after)).unwrap(), mine);
}

#[test]
fn the_inventory_reads_a_repositorys_own_hooks_when_nothing_owned_the_hooks_path() {
    let machine = Machine::new();
    machine.install();
    let repo = machine.repo("old");
    let findings = |repo: &Repo| {
        let status = machine.push_hook("status", repo, &[]);
        let report: Value = serde_json::from_slice(&status.stdout).unwrap();
        report["legacy"]["findings"].clone()
    };
    assert_eq!(findings(&repo), serde_json::json!([]), "ours aren't v1");
    let v1 = repo.dir.join(".git/hooks/pre-commit");
    fs::write(&v1, "#!/bin/sh\n# VibeGuard Pre-Commit Hook Wrapper\n").unwrap();
    let found = findings(&repo);
    assert_eq!(found.as_array().unwrap().len(), 1, "{found}");
    assert_eq!(found[0]["evidence"], "owned");
    assert_eq!(found[0]["location"], v1.to_str().unwrap());
}

#[test]
fn the_inventory_doesnt_take_our_block_in_another_tools_hook_for_v1() {
    let machine = Machine::new();
    // Not other_tools_hooks(): its log path is under this fixture's "vibeguard-" directory.
    let dir = machine.base.join("other");
    fs::create_dir_all(&dir).unwrap();
    machine.config(&["core.hooksPath", dir.to_str().unwrap()]);
    let chain = dir.join("pre-commit");
    fs::write(&chain, "#!/bin/sh\nexit 0\n").unwrap();
    machine.install();
    let repo = machine.repo("r");
    let status = machine.push_hook("status", &repo, &[]);
    let report: Value = serde_json::from_slice(&status.stdout).unwrap();
    assert_eq!(report["legacy"]["findings"], serde_json::json!([]));
    let words = String::from_utf8_lossy(&status.stderr);
    assert!(!words.contains("v1 remnants"), "{words}");
    // What the other tool wrote itself is still read.
    let text = fs::read_to_string(&chain).unwrap();
    fs::write(
        &chain,
        text.replace("exit 0", "bash ~/.vibeguard/run-hook.sh x\nexit 0"),
    )
    .unwrap();
    let status = machine.push_hook("status", &repo, &[]);
    let report: Value = serde_json::from_slice(&status.stdout).unwrap();
    assert_eq!(report["legacy"]["findings"][0]["evidence"], "suspected");
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

/// Installs where a `core.hooksPath` is in effect that the main global file doesn't
/// hold, so `git config --global` alone reports none.
fn hooks_path_set_elsewhere(layout: &str) {
    let machine = Machine::new();
    let (chain, text) = machine.other_tools_scripts();
    let dir = chain.parent().unwrap();
    let setting = format!("[core]\n\thooksPath = {}\n", dir.display());
    if layout == "system" {
        fs::write(machine.system_gitconfig(), setting).unwrap();
    } else {
        let included = machine.base.join("included.gitconfig");
        fs::write(&included, setting).unwrap();
        if layout == "included after core" {
            // Git would add a `core.hooksPath` to this section, ahead of the included
            // one, which then stays the one in effect.
            machine.config(&["core.autocrlf", "false"]);
        }
        machine.config(&["include.path", included.to_str().unwrap()]);
    }
    let global = fs::read_to_string(machine.gitconfig()).unwrap();
    machine.install();
    assert!(machine.setup("status", &[]).status.success());
    let repo = machine.repo("r");
    repo.write("big.rs", 950);
    let refused = repo.commit();
    assert!(refused.is_err_and(|words| words.contains("grew")));
    repo.write("big.rs", 900);
    repo.write("small.rs", 11);
    repo.commit().unwrap();
    let ran = fs::read_to_string(chain.with_file_name("log")).unwrap_or_default();
    assert!(ran.contains("ran pre-commit"), "the other tool's: {ran}");
    assert!(machine.setup("uninstall", &[]).status.success());
    assert_eq!(fs::read_to_string(&chain).unwrap(), text);
    assert_eq!(fs::read_to_string(machine.gitconfig()).unwrap(), global);
}

#[test]
fn a_hooks_path_from_an_included_file_is_another_tools_too() {
    hooks_path_set_elsewhere("included");
}

#[test]
fn a_hooks_path_included_after_the_core_section_is_another_tools_too() {
    hooks_path_set_elsewhere("included after core");
}

#[test]
fn a_hooks_path_from_the_system_configuration_is_another_tools_too() {
    hooks_path_set_elsewhere("system");
}

#[test]
fn a_hook_vibeguard_cant_edit_is_left_alone() {
    // Python both times. The first path to it has the letters "sh" in it.
    for interpreter in ["/Users/josh/.pyenv/shims/python", "/usr/bin/env python3"] {
        let machine = Machine::new();
        let dir = machine.base.join("other-tool");
        fs::create_dir_all(&dir).unwrap();
        machine.config(&["core.hooksPath", dir.to_str().unwrap()]);
        let hook = dir.join("pre-commit");
        let text = format!("#!{interpreter}\nprint('mine')\n");
        fs::write(&hook, &text).unwrap();
        let refused = machine.setup("install", &[]);
        assert!(!refused.status.success(), "{interpreter}");
        let words = String::from_utf8_lossy(&refused.stderr);
        assert!(words.contains("not a POSIX shell script"), "{words}");
        assert_eq!(fs::read_to_string(&hook).unwrap(), text, "{interpreter}");
    }
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
fn a_git_the_check_cant_use_is_refused_before_setup_reports_protection() {
    // Git before 2.45 has no --no-lazy-fetch, which every inspection in the check uses.
    let machine = Machine::new();
    let bin = machine.base.join("old-git");
    fs::create_dir_all(&bin).unwrap();
    let real = Command::new("sh")
        .args(["-c", "command -v git"])
        .output()
        .unwrap();
    let real = String::from_utf8(real.stdout).unwrap();
    fs::write(
        bin.join("git"),
        format!(
            "#!/bin/sh\nfor a; do [ \"$a\" = --no-lazy-fetch ] && exit 129; done\nexec {} \"$@\"\n",
            real.trim()
        ),
    )
    .unwrap();
    fs::set_permissions(bin.join("git"), fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap());
    let run = |action: &str, extra: &[&str]| {
        Command::new(BIN)
            .current_dir(&machine.base)
            .env("PATH", &path)
            .env("GIT_CONFIG_SYSTEM", machine.system_gitconfig())
            .env_remove("GIT_CONFIG_NOSYSTEM")
            .args([action, "git-size", "--home"])
            .arg(machine.base.join("home"))
            .args(extra)
            .output()
            .unwrap()
    };
    for (action, extra) in [
        ("install", &["--dry-run"][..]),
        ("install", &[]),
        ("status", &[]),
    ] {
        let output = run(action, extra);
        let words = String::from_utf8_lossy(&output.stderr);
        assert_eq!(output.status.code(), Some(2), "{action} {extra:?}: {words}");
        assert!(words.contains("Git 2.45"), "{action} {extra:?}: {words}");
    }
    assert_eq!(machine.hooks_path(), None);
    assert!(!machine.base.join("home/.vibeguard").exists());
    machine.install();
    let output = run("uninstall", &[]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(machine.hooks_path(), None);
}

#[test]
fn a_dry_run_changes_nothing() {
    let machine = Machine::new();
    let output = machine.setup("install", &["--dry-run"]);
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("set_global_git_config"));
    assert_eq!(machine.hooks_path(), None);
    let left: Vec<_> = fs::read_dir(machine.base.join("home"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect();
    assert_eq!(left, [".gitconfig"], "the fixture's own file and no more");
}

#[test]
fn a_named_home_keeps_out_of_the_accounts_global_git_configuration() {
    let machine = Machine::new();
    let account = machine.base.join("account");
    let theirs = account.join("hooks");
    // The two places an account's environment can move its global configuration to.
    // Git reads and writes them whatever HOME says.
    let xdg = account.join("xdg/git/config");
    let named = account.join("named");
    fs::create_dir_all(xdg.parent().unwrap()).unwrap();
    let plain = "[user]\n\tname = account\n".to_owned();
    let hooked = format!("{plain}[core]\n\thooksPath = {}\n", theirs.display());
    let cases = [
        ("XDG_CONFIG_HOME", account.join("xdg"), &xdg),
        ("GIT_CONFIG_GLOBAL", named.clone(), &named),
    ];
    for (variable, value, file) in cases {
        for (text, kind) in [(&plain, "plain"), (&hooked, "hooked")] {
            fs::write(file, text).unwrap();
            let home = machine.base.join(format!("{variable}-{kind}"));
            let output = Command::new(BIN)
                .current_dir(&machine.base)
                .env_remove("XDG_CONFIG_HOME")
                .env_remove("GIT_CONFIG_GLOBAL")
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .env("HOME", &account)
                .env(variable, &value)
                .args(["install", "git-size", "--home"])
                .arg(&home)
                .output()
                .unwrap();
            let case = format!("{variable}, {kind}");
            let words = String::from_utf8_lossy(&output.stderr);
            assert!(output.status.success(), "{case}: {words}");
            assert_eq!(&fs::read_to_string(file).unwrap(), text, "{case}");
            assert!(!theirs.exists(), "{case}: the account's hooks");
            let own = fs::read_to_string(home.join(".gitconfig")).unwrap();
            let hooks = home.join(".vibeguard/git-hooks");
            assert!(own.contains(hooks.to_str().unwrap()), "{case}: {own}");
        }
    }
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
