#![cfg(unix)]

use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::symlink;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_vibeguard-runtime");
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "vibeguard-legacy-{}-{}",
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

fn run(args: &[&str], home: &Path, extra: &[(&str, &Path)]) -> Output {
    let mut command = Command::new(BIN);
    command
        .args(args)
        .env("HOME", home)
        .env_remove("CODEX_HOME")
        .env_remove("GEMINI_CLI_HOME")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (key, value) in extra {
        command.env(key, value);
    }
    command.output().unwrap()
}

fn json_output(output: &Output) -> Value {
    serde_json::from_slice(&output.stdout).unwrap_or_else(|_| {
        panic!(
            "stdout={}\nstderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    })
}

fn evidences<'a>(report: &'a Value, category: &str) -> Vec<&'a str> {
    report["legacy"]["findings"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|finding| finding["category"] == category)
        .map(|finding| finding["evidence"].as_str().unwrap())
        .collect()
}

fn run_bounded(args: &[&str], home: &Path, timeout: Duration) -> Output {
    let mut child = Command::new(BIN)
        .args(args)
        .env("HOME", home)
        .env_remove("CODEX_HOME")
        .env_remove("GEMINI_CLI_HOME")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn()
        .unwrap();
    let deadline = Instant::now() + timeout;
    while child.try_wait().unwrap().is_none() {
        if Instant::now() >= deadline {
            // Include an in-flight Git probe when failing a regression timeout.
            let _ = Command::new("kill")
                .args(["-s", "KILL", "--", &format!("-{}", child.id())])
                .status();
            let _ = child.kill();
            child.wait().unwrap();
            panic!("{args:?} blocked while inspecting a nonregular legacy file");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    child.wait_with_output().unwrap()
}

#[test]
fn nonregular_legacy_files_do_not_block_install_status_or_uninstall() {
    let temp = Temp::new();
    fs::create_dir(temp.0.join(".gemini")).unwrap();
    let paths = [
        temp.0.join(".gemini/settings.json"),
        temp.0.join(".gemini/GEMINI.md"),
    ];
    assert!(
        Command::new("mkfifo")
            .args(&paths)
            .status()
            .unwrap()
            .success()
    );
    for action in ["install", "status", "uninstall"] {
        let output = run_bounded(
            &[action, "claude", "--home", temp.0.to_str().unwrap()],
            &temp.0,
            Duration::from_secs(5),
        );
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let report = json_output(&output);
        for path in &paths {
            assert!(
                report["legacy"]["findings"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|item| {
                        item["location"] == path.to_str().unwrap()
                            && item["evidence"] == "not_checked"
                            && item["detail"]
                                .as_str()
                                .unwrap()
                                .contains("not a regular file")
                    })
            );
        }
    }
}

#[test]
fn blocked_git_configuration_is_advisory_and_normal_inspection_recovers() {
    let temp = Temp::new();
    let home = temp.0.join("home");
    let repo = temp.0.join("repo");
    fs::create_dir(&home).unwrap();
    assert!(
        Command::new("git")
            .args(["init", "-q"])
            .arg(&repo)
            .status()
            .unwrap()
            .success()
    );
    fs::write(
        repo.join("CLAUDE.md"),
        "<!-- vibeguard-start -->\nold\n<!-- vibeguard-end -->\n",
    )
    .unwrap();
    let run = |action: &str| {
        run_bounded(
            &[
                action,
                "claude",
                "--home",
                home.to_str().unwrap(),
                "--repo",
                repo.to_str().unwrap(),
            ],
            &home,
            Duration::from_secs(15),
        )
    };
    // A real Git control establishes that the root is normally inspected.
    let before = run("status");
    assert_eq!(before.status.code(), Some(1));
    assert_eq!(evidences(&json_output(&before), "markdown"), vec!["owned"]);
    let config_path = repo.join(".git/config");
    let original_config = fs::read(&config_path).unwrap();
    fs::remove_file(&config_path).unwrap();
    assert!(
        Command::new("mkfifo")
            .arg(&config_path)
            .status()
            .unwrap()
            .success()
    );

    let installed = run("install");
    assert!(
        installed.status.success(),
        "{}",
        String::from_utf8_lossy(&installed.stderr)
    );
    let report = json_output(&installed);
    assert_eq!(report["action"], "install");
    assert_eq!(report["host"], "claude");
    let unavailable: Vec<_> = report["legacy"]["findings"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|item| {
            item["category"] == "repository_root" || item["category"] == "repository_hook"
        })
        .collect();
    assert_eq!(unavailable.len(), 3);
    assert!(
        unavailable
            .iter()
            .all(|item| item["evidence"] == "not_checked"
                && item["detail"].as_str().unwrap().contains("timed out"))
    );
    assert!(home.join(".vibeguard/bin/vibeguard-runtime").is_file());
    let installed_settings: Value =
        serde_json::from_slice(&fs::read(home.join(".claude/settings.json")).unwrap()).unwrap();
    assert_eq!(installed_settings["hooks"].as_object().unwrap().len(), 3);

    fs::remove_file(&config_path).unwrap();
    fs::write(&config_path, original_config).unwrap();
    let recovered = run("status");
    assert!(recovered.status.success());
    let report = json_output(&recovered);
    assert_eq!(evidences(&report, "markdown"), vec!["owned"]);
    assert!(
        !report["legacy"]["findings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| {
                (item["category"] == "repository_root" || item["category"] == "repository_hook")
                    && item["evidence"] == "not_checked"
            })
    );
}

#[test]
fn repository_inventory_resolves_worktree_root_from_a_subdirectory() {
    let temp = Temp::new();
    let repo = temp.0.join("repo");
    let nested = repo.join("src/deep");
    fs::create_dir_all(&nested).unwrap();
    assert!(
        Command::new("git")
            .args(["init", "-q"])
            .arg(&repo)
            .status()
            .unwrap()
            .success()
    );
    fs::write(
        repo.join("CLAUDE.md"),
        "<!-- vibeguard-start -->\nold\n<!-- vibeguard-end -->\n",
    )
    .unwrap();
    fs::create_dir(repo.join(".claude")).unwrap();
    fs::write(
        repo.join(".claude/settings.json"),
        json!({"hooks":{"PreToolUse":[{"hooks":[{
            "type":"command", "command":"bash /home/user/.vibeguard/run-hook.sh"
        }]}]}})
        .to_string(),
    )
    .unwrap();
    let mut reports = Vec::new();
    for directory in [&repo, &nested] {
        let output = run(
            &[
                "status",
                "git",
                "--home",
                temp.0.to_str().unwrap(),
                "--repo",
                directory.to_str().unwrap(),
            ],
            &temp.0,
            &[],
        );
        let report = json_output(&output);
        let findings: Vec<_> = report["legacy"]["findings"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|item| item["category"] == "markdown" || item["category"] == "handler")
            .cloned()
            .collect();
        assert_eq!(findings.len(), 2);
        reports.push(findings);
    }
    assert_eq!(reports[0], reports[1]);
}

#[test]
fn bare_repository_has_no_worktree_instruction_inventory() {
    let temp = Temp::new();
    let repo = temp.0.join("bare.git");
    assert!(
        Command::new("git")
            .args(["init", "--bare", "-q"])
            .arg(&repo)
            .status()
            .unwrap()
            .success()
    );
    fs::write(
        repo.join("CLAUDE.md"),
        "<!-- vibeguard-start -->\nold\n<!-- vibeguard-end -->\n",
    )
    .unwrap();
    let output = run(
        &[
            "status",
            "git",
            "--home",
            temp.0.to_str().unwrap(),
            "--repo",
            repo.to_str().unwrap(),
        ],
        &temp.0,
        &[],
    );
    let report = json_output(&output);
    assert!(evidences(&report, "markdown").is_empty());
    assert!(evidences(&report, "repository_root").is_empty());
}

#[test]
fn generic_script_suffixes_remain_suspected_instead_of_owned() {
    let temp = Temp::new();
    fs::create_dir(temp.0.join(".claude")).unwrap();
    fs::write(
        temp.0.join(".claude/settings.json"),
        json!({"hooks":{"PreToolUse":[{"hooks":[{
            "type":"command", "command":"bash /opt/acme-tools/run-hook.sh"
        }]}]}})
        .to_string(),
    )
    .unwrap();
    let output = run(
        &["status", "claude", "--home", temp.0.to_str().unwrap()],
        &temp.0,
        &[],
    );
    assert_eq!(
        evidences(&json_output(&output), "handler"),
        vec!["suspected"]
    );
    assert!(String::from_utf8_lossy(&output.stderr).contains("possible v1 remnants"));
}

#[test]
fn fresh_install_status_and_uninstall_have_no_legacy_findings() {
    let temp = Temp::new();
    let home = temp.0.join("home");
    fs::create_dir(&home).unwrap();
    let home_arg = home.to_str().unwrap();
    for action in ["install", "status", "uninstall"] {
        let output = run(&[action, "codex", "--home", home_arg], &home, &[]);
        assert!(
            output.status.success(),
            "{action}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let report = json_output(&output);
        assert_eq!(report["legacy"]["findings"], json!([]));
        assert_eq!(report["legacy"]["presence_proves_execution"], false);
        assert_eq!(
            report["legacy"]["scheduler"]["crontab"]["access"],
            "not_applicable"
        );
        assert_eq!(report["legacy"]["scheduler"]["launchd"]["present"], false);
        assert_eq!(report["legacy"]["scheduler"]["systemd"]["present"], false);
        assert!(
            report["legacy"]["migration"]["v1_source_uninstall"]
                .as_str()
                .unwrap()
                .contains("setup.sh --clean")
        );
        assert!(
            report["legacy"]["migration"]["release_install"]
                .as_str()
                .unwrap()
                .contains("./vibeguard-runtime install")
        );
        if action == "status" {
            let summary = String::from_utf8_lossy(&output.stderr);
            assert!(summary.contains("codex setup complete"), "{summary}");
            assert!(
                summary.contains("host trust remains unobserved"),
                "{summary}"
            );
            assert!(summary.contains("status codex --home"), "{summary}");
        } else {
            assert!(output.stderr.is_empty(), "{action}");
        }
    }
}

#[test]
fn unreadable_legacy_location_is_not_reported_as_clean() {
    let temp = Temp::new();
    let home = temp.0.join("home");
    fs::create_dir(&home).unwrap();
    let home_arg = home.to_str().unwrap();
    assert!(
        run(&["install", "codex", "--home", home_arg], &home, &[])
            .status
            .success()
    );
    fs::create_dir_all(home.join(".gemini")).unwrap();
    fs::write(home.join(".gemini/settings.json"), [0xff]).unwrap();
    let status = run(&["status", "codex", "--home", home_arg], &home, &[]);
    assert!(status.status.success());
    let report = json_output(&status);
    assert!(
        report["legacy"]["findings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["evidence"] == "not_checked")
    );
    let summary = String::from_utf8_lossy(&status.stderr);
    assert!(
        summary.contains("legacy inventory is incomplete"),
        "{summary}"
    );
}

#[test]
fn coexistence_is_reported_without_running_handlers_or_editing_crontab() {
    let temp = Temp::new();
    let home = temp.0.join("home");
    let repo = temp.0.join("repo");
    fs::create_dir_all(home.join(".claude")).unwrap();
    fs::create_dir_all(home.join(".vibeguard/installed/hooks")).unwrap();
    fs::create_dir_all(home.join("Library/LaunchAgents")).unwrap();
    let sentinel = home.join("SHOULD_NOT_EXIST");
    let wrapper = home.join(".vibeguard/run-hook.sh");
    fs::write(&wrapper, "#!/bin/sh\ntouch SHOULD_NOT_EXIST\n").unwrap();
    let command = format!("bash '{}'", wrapper.display());
    let user_hook = json!({"type":"command","command":"echo user-hook","timeout":17});
    let legacy_hook = json!({"type":"command","command":command,"timeout":10});
    let config = json!({
        "custom": true,
        "hooks": {"PreToolUse": [{"matcher":"Bash","hooks":[user_hook, legacy_hook]}]}
    });
    let config_path = home.join(".claude/settings.json");
    fs::write(&config_path, serde_json::to_string_pretty(&config).unwrap()).unwrap();
    let instructions = home.join(".claude/CLAUDE.md");
    let user_text = "\
User-owned instructions\r
The old notes mention run-hook.sh in prose.
<!-- vibeguard-start -->
old rules
<!-- vibeguard-end -->
```
<!-- vibeguard-start -->
<!-- vibeguard-end -->
```
";
    fs::write(&instructions, user_text).unwrap();
    fs::write(
        home.join("Library/LaunchAgents/com.vibeguard.gc.plist"),
        "gc-scheduled.sh\n",
    )
    .unwrap();
    fs::create_dir_all(&repo).unwrap();
    assert!(
        Command::new("git")
            .args(["init", repo.to_str().unwrap()])
            .status()
            .unwrap()
            .success()
    );
    assert!(
        Command::new("git")
            .args([
                "-C",
                repo.to_str().unwrap(),
                "config",
                "core.hooksPath",
                ".git/hooks"
            ])
            .status()
            .unwrap()
            .success()
    );
    fs::write(
        repo.join("README.md"),
        "documentation mentions <!-- vibeguard-start --> and run-hook.sh\n",
    )
    .unwrap();
    let git_hooks = repo.join(".git/hooks");
    fs::create_dir_all(&git_hooks).unwrap();
    let pre_commit = home.join(".vibeguard/pre-commit");
    fs::write(&pre_commit, "#!/bin/sh\ntouch SHOULD_NOT_EXIST\n").unwrap();
    symlink(&pre_commit, git_hooks.join("pre-commit")).unwrap();
    let before_cron = Command::new("crontab").arg("-l").output().unwrap();

    let home_arg = home.to_str().unwrap();
    let repo_arg = repo.to_str().unwrap();
    let installed = run(
        &["install", "claude", "--home", home_arg, "--repo", repo_arg],
        &home,
        &[],
    );
    assert!(
        installed.status.success(),
        "{}",
        String::from_utf8_lossy(&installed.stderr)
    );
    let report = json_output(&installed);
    assert!(evidences(&report, "handler").contains(&"owned"));
    assert!(evidences(&report, "markdown").contains(&"owned"));
    assert!(evidences(&report, "markdown").contains(&"suspected"));
    assert!(evidences(&report, "install_path").contains(&"owned"));
    assert!(evidences(&report, "scheduler").contains(&"owned"));
    assert!(
        evidences(&report, "repository_hook").contains(&"owned"),
        "{}",
        report["legacy"]["findings"]
    );
    assert!(
        !report["legacy"]["findings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|finding| finding["location"].as_str().unwrap().ends_with("README.md"))
    );
    assert!(String::from_utf8_lossy(&installed.stderr).contains("were not executed"));
    let status = run(
        &["status", "claude", "--home", home_arg, "--repo", repo_arg],
        &home,
        &[],
    );
    assert!(status.status.success());
    let summary = String::from_utf8_lossy(&status.stderr);
    assert!(
        summary.contains("claude setup complete, with known v1 remnants"),
        "{summary}"
    );
    assert!(
        summary.contains("legacy.findings and legacy.migration"),
        "{summary}"
    );
    assert!(!summary.contains("setup.sh --clean"), "{summary}");
    assert_eq!(
        json_output(&status)["legacy"]["findings"],
        report["legacy"]["findings"]
    );
    assert!(!sentinel.exists());
    let text = fs::read_to_string(&instructions).unwrap();
    assert!(text.contains("User-owned instructions"));
    assert!(text.contains("<!-- vibeguard-start -->"));
    assert!(!text.contains("<!-- vibeguard-core:start -->"));
    let saved: Value = serde_json::from_str(&fs::read_to_string(&config_path).unwrap()).unwrap();
    assert_eq!(saved["custom"], true);
    let handlers = saved["hooks"]["PreToolUse"][0]["hooks"].as_array().unwrap();
    assert!(
        handlers
            .iter()
            .any(|hook| hook["command"] == "echo user-hook")
    );
    assert!(
        handlers
            .iter()
            .any(|hook| { hook["command"].as_str().unwrap().contains("run-hook.sh") })
    );

    let removed = run(
        &[
            "uninstall",
            "claude",
            "--home",
            home_arg,
            "--repo",
            repo_arg,
        ],
        &home,
        &[],
    );
    assert!(removed.status.success());
    let saved: Value = serde_json::from_str(&fs::read_to_string(&config_path).unwrap()).unwrap();
    let handlers = saved["hooks"]["PreToolUse"][0]["hooks"].as_array().unwrap();
    assert_eq!(handlers.len(), 2);
    assert!(
        fs::read_to_string(&instructions)
            .unwrap()
            .contains("<!-- vibeguard-start -->")
    );
    assert!(!sentinel.exists());
    let after_cron = Command::new("crontab").arg("-l").output().unwrap();
    assert_eq!(before_cron.status.code(), after_cron.status.code());
    assert_eq!(before_cron.stdout, after_cron.stdout);
}

#[test]
fn explicit_home_ignores_ambient_codex_and_gemini_directories() {
    let temp = Temp::new();
    let home = temp.0.join("home");
    let codex = temp.0.join("codex-home");
    let gemini_root = temp.0.join("gemini-root");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&codex).unwrap();
    fs::create_dir_all(gemini_root.join(".gemini")).unwrap();
    fs::write(
        codex.join("hooks.json"),
        json!({"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash '/opt/.vibeguard/run-hook-codex.sh'"}]}]}}).to_string(),
    )
    .unwrap();
    fs::write(
        gemini_root.join(".gemini/settings.json"),
        json!({"hooks":{"BeforeTool":[{"hooks":[{"type":"command","command":"bash '/opt/.vibeguard/run-hook-gemini.sh'"}]}]}}).to_string(),
    )
    .unwrap();
    let output = run(
        &["status", "claude", "--home", home.to_str().unwrap()],
        &home,
        &[("CODEX_HOME", &codex), ("GEMINI_CLI_HOME", &gemini_root)],
    );
    assert_eq!(output.status.code(), Some(1));
    let report = json_output(&output);
    assert_eq!(report["legacy"]["findings"], json!([]));

    let visible = Command::new(BIN)
        .args(["status", "claude"])
        .env("HOME", &home)
        .env("CODEX_HOME", &codex)
        .env("GEMINI_CLI_HOME", &gemini_root)
        .output()
        .unwrap();
    let report = json_output(&visible);
    let locations: Vec<_> = report["legacy"]["findings"]
        .as_array()
        .unwrap()
        .iter()
        .map(|finding| finding["location"].as_str().unwrap().to_string())
        .collect();
    assert!(
        locations
            .iter()
            .any(|location| location.ends_with("hooks.json"))
    );
    assert!(
        locations
            .iter()
            .any(|location| location.ends_with("settings.json"))
    );
}
