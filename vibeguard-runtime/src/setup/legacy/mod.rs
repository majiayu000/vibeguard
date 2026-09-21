use super::Options;
mod classify;
mod process;

use classify::{
    classify_command, command_detail, crontab_findings, finding, lexical_join, markdown_findings,
    mentions_v1, not_checked, owned_word, path_text, suspected, v1_hook_body,
};
#[cfg(any(target_os = "macos", target_os = "linux"))]
use process::account_home;
use process::{CommandOutput, command_output};

use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

const READ_LIMIT: u64 = 1024 * 1024;

pub fn inventory(options: &Options) -> Value {
    let mut findings = Vec::new();
    for path in [
        options.home.join(".claude/settings.json"),
        options.codex_dir.join("hooks.json"),
        options.gemini_dir.join("settings.json"),
    ] {
        inspect_hook_config(&path, &mut findings);
    }
    for path in [
        options.home.join(".claude/CLAUDE.md"),
        options.codex_dir.join("AGENTS.md"),
        options.gemini_dir.join("GEMINI.md"),
    ] {
        inspect_markdown(&path, &mut findings);
    }
    inspect_install_paths(&options.home, &mut findings);
    if options.inspect_repo {
        inspect_repository(&options.repo, &mut findings);
    }
    let (crontab, cron_findings) = crontab_report(&options.home);
    findings.extend(cron_findings);
    let launchd = scheduler_file(
        &options
            .home
            .join("Library/LaunchAgents/com.vibeguard.gc.plist"),
        "v1 launchd GC plist",
        &mut findings,
    );
    let service = options
        .home
        .join(".config/systemd/user/vibeguard-gc.service");
    let timer = options.home.join(".config/systemd/user/vibeguard-gc.timer");
    let service_state = scheduler_file(&service, "v1 systemd GC service", &mut findings);
    let timer_state = scheduler_file(&timer, "v1 systemd GC timer", &mut findings);
    json!({
        "presence_proves_execution": false,
        "findings": findings,
        "scheduler": {
            "crontab": crontab,
            "launchd": launchd,
            "systemd": {
                "access": if service_state["access"] == "not_checked" || timer_state["access"] == "not_checked" {
                    "not_checked"
                } else {
                    "checked"
                },
                "present": service_state["present"] == true || timer_state["present"] == true,
                "service": service_state,
                "timer": timer_state,
            }
        },
        "migration": {
            "sequence": [
                "Back up the host files named in findings.",
                "From the installed v1 source checkout, run: bash setup.sh --clean",
                "From a v1 release snapshot, run: bash ~/.vibeguard/dist/current/setup.sh --clean",
                "Review residual Git hooks and scheduler entries. Deleting the v1 checkout leaves them in place.",
                "Install v2 from the source tree with bash setup.sh install <claude|codex>, or from an extracted release archive with ./vibeguard-runtime install <claude|codex>.",
                "Restart the host, run one harmless Bash command, then read status last_observation."
            ],
            "source_install": "bash setup.sh install <claude|codex>",
            "release_install": "./vibeguard-runtime install <claude|codex>",
            "v1_source_uninstall": "bash setup.sh --clean",
            "v1_release_uninstall": "bash ~/.vibeguard/dist/current/setup.sh --clean",
            "note": "Installing v2 does not deactivate v1. This inventory does not execute discovered commands or edit crontab."
        }
    })
}

pub fn attention_message(report: &Value) -> Option<&'static str> {
    let findings = report["findings"].as_array().map(Vec::len).unwrap_or(0) > 0;
    let unchecked = ["crontab", "launchd"]
        .into_iter()
        .any(|name| report["scheduler"][name]["access"] == "not_checked")
        || report["scheduler"]["systemd"]["access"] == "not_checked";
    (findings || unchecked).then_some(
        "VibeGuard: status found v1 remnants or could not check a scheduler. Locations and uninstall commands are in the legacy JSON field. Discovered commands were not executed.",
    )
}

fn inspect_hook_config(path: &Path, findings: &mut Vec<Value>) {
    match read_record(path) {
        Record::Missing => {}
        Record::Symlink => findings.push(suspected(
            path,
            "handler",
            "configuration symlink was not followed and was not executed",
        )),
        Record::Error(detail) | Record::TooBig(detail) | Record::NotUtf8(detail) => {
            findings.push(not_checked(path, "handler", &detail));
        }
        Record::Directory => {
            findings.push(suspected(path, "handler", "expected a configuration file"))
        }
        Record::Text(text) => match serde_json::from_str::<Value>(&text) {
            Ok(value) => walk_commands(path, &value, findings),
            Err(_) => findings.push(not_checked(
                path,
                "handler",
                "invalid JSON; handlers were not inspected",
            )),
        },
    }
}

fn walk_commands(path: &Path, value: &Value, findings: &mut Vec<Value>) {
    let Some(hooks) = value.get("hooks").and_then(Value::as_object) else {
        return;
    };
    for (event, groups) in hooks {
        let Some(groups) = groups.as_array() else {
            findings.push(not_checked(
                path,
                "handler",
                &format!("{event} is not an array"),
            ));
            continue;
        };
        for group in groups {
            let Some(handlers) = group.get("hooks").and_then(Value::as_array) else {
                continue;
            };
            for handler in handlers {
                let Some(command) = handler.get("command").and_then(Value::as_str) else {
                    continue;
                };
                if let Some(evidence) = classify_command(command) {
                    findings.push(finding(
                        evidence,
                        path,
                        "handler",
                        &command_detail(command, evidence),
                        Some(event),
                    ));
                }
            }
        }
    }
}

fn inspect_markdown(path: &Path, findings: &mut Vec<Value>) {
    match read_record(path) {
        Record::Missing => {}
        Record::Symlink => findings.push(suspected(
            path,
            "markdown",
            "instruction symlink was not followed and was not executed",
        )),
        Record::Error(detail) | Record::TooBig(detail) | Record::NotUtf8(detail) => {
            findings.push(not_checked(path, "markdown", &detail));
        }
        Record::Directory => {
            findings.push(suspected(path, "markdown", "expected an instruction file"))
        }
        Record::Text(text) => findings.extend(markdown_findings(path, &text)),
    }
}

fn inspect_install_paths(home: &Path, findings: &mut Vec<Value>) {
    for (path, detail, directory) in [
        (
            home.join(".vibeguard/installed"),
            "v1 installed snapshot",
            true,
        ),
        (
            home.join(".vibeguard/dist/current"),
            "v1 release snapshot",
            true,
        ),
        (
            home.join(".vibeguard/run-hook.sh"),
            "v1 Claude wrapper",
            false,
        ),
        (
            home.join(".vibeguard/run-hook-codex.sh"),
            "v1 Codex wrapper",
            false,
        ),
        (
            home.join(".vibeguard/run-hook-gemini.sh"),
            "v1 Gemini wrapper",
            false,
        ),
        (
            home.join(".vibeguard/pre-commit"),
            "v1 pre-commit wrapper",
            false,
        ),
        (
            home.join(".vibeguard/pre-push"),
            "v1 pre-push wrapper",
            false,
        ),
        (
            home.join(".vibeguard/execution-mode"),
            "v1 execution-mode file",
            false,
        ),
        (
            home.join(".vibeguard/repo-path"),
            "v1 repo-path file",
            false,
        ),
        (
            home.join(".vibeguard/gemini-enabled"),
            "v1 Gemini marker",
            false,
        ),
    ] {
        classify_product_path(&path, detail, directory, findings);
    }
}

fn classify_product_path(path: &Path, detail: &str, directory: bool, findings: &mut Vec<Value>) {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => findings.push(not_checked(path, "install_path", &error.to_string())),
        Ok(metadata) if metadata.file_type().is_symlink() => findings.push(suspected(
            path,
            "install_path",
            "symlink was not followed and was not executed",
        )),
        Ok(metadata) if directory == metadata.is_dir() || (!directory && metadata.is_file()) => {
            findings.push(finding("owned", path, "install_path", detail, None));
        }
        Ok(_) => findings.push(suspected(
            path,
            "install_path",
            "path exists with an unexpected type",
        )),
    }
}

fn scheduler_file(path: &Path, detail: &str, findings: &mut Vec<Value>) -> Value {
    let location = path_text(path);
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            json!({"access":"checked","present":false,"path":location})
        }
        Err(error) => {
            findings.push(not_checked(path, "scheduler", &error.to_string()));
            json!({"access":"not_checked","present":false,"path":location,"detail":error.to_string()})
        }
        Ok(metadata) if metadata.file_type().is_symlink() => {
            findings.push(suspected(
                path,
                "scheduler",
                "symlink was not followed and was not executed",
            ));
            json!({"access":"checked","present":false,"path":location,"detail":"symlink"})
        }
        Ok(metadata) if metadata.is_file() => {
            findings.push(finding("owned", path, "scheduler", detail, None));
            json!({"access":"checked","present":true,"path":location})
        }
        Ok(_) => {
            findings.push(suspected(path, "scheduler", "expected a regular file"));
            json!({"access":"checked","present":false,"path":location,"detail":"unexpected type"})
        }
    }
}

fn inspect_repository(repo: &Path, findings: &mut Vec<Value>) {
    for name in ["CLAUDE.md", "AGENTS.md", "GEMINI.md"] {
        inspect_markdown(&repo.join(name), findings);
    }
    inspect_hook_config(&repo.join(".claude/settings.json"), findings);
    for hook in ["pre-commit", "pre-push"] {
        match git_hook_path(repo, hook) {
            Ok(path) => inspect_git_hook(&path, findings),
            Err(detail) => findings.push(finding(
                "not_checked",
                repo,
                "repository_hook",
                &format!("{hook}: {detail}"),
                None,
            )),
        }
    }
}

fn inspect_git_hook(path: &Path, findings: &mut Vec<Value>) {
    // Git may return the symlink target. The product path is still the evidence.
    if owned_word(&path_text(path)) {
        findings.push(finding(
            "owned",
            path,
            "repository_hook",
            "git hook path is a v1 product file",
            None,
        ));
        return;
    }
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => findings.push(not_checked(path, "repository_hook", &error.to_string())),
        Ok(metadata) if metadata.file_type().is_symlink() => match fs::read_link(path) {
            Ok(target) => {
                let resolved = lexical_join(path.parent().unwrap_or(Path::new(".")), &target);
                if owned_word(&resolved) {
                    findings.push(finding(
                        "owned",
                        path,
                        "repository_hook",
                        &format!("symlink to {resolved}"),
                        None,
                    ));
                } else if mentions_v1(&resolved) {
                    findings.push(suspected(
                        path,
                        "repository_hook",
                        "symlink mentions v1 names and was not followed",
                    ));
                }
            }
            Err(error) => findings.push(not_checked(path, "repository_hook", &error.to_string())),
        },
        Ok(metadata) if metadata.is_file() => match read_record(path) {
            Record::Text(text) => {
                if v1_hook_body(&text) {
                    findings.push(finding(
                        "owned",
                        path,
                        "repository_hook",
                        "v1 hook wrapper text",
                        None,
                    ));
                } else if mentions_v1(&text) && !text.contains("# VibeGuard native pre-push hook") {
                    findings.push(suspected(
                        path,
                        "repository_hook",
                        "hook text mentions v1 names and was not executed",
                    ));
                }
            }
            Record::TooBig(detail) | Record::NotUtf8(detail) | Record::Error(detail) => {
                findings.push(not_checked(path, "repository_hook", &detail));
            }
            Record::Missing | Record::Symlink | Record::Directory => {}
        },
        Ok(_) => findings.push(suspected(
            path,
            "repository_hook",
            "expected a file or symlink",
        )),
    }
}

fn git_hook_path(repo: &Path, hook: &str) -> Result<PathBuf, String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args([
            "rev-parse",
            "--path-format=absolute",
            "--git-path",
            &format!("hooks/{hook}"),
        ])
        .output()
        .map_err(|error| format!("git rev-parse failed: {error}"))?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr);
        return Err(detail.trim().to_string());
    }
    let text = String::from_utf8(output.stdout).map_err(|_| "git path is not UTF-8".to_string())?;
    let path = text.trim();
    if path.is_empty() {
        return Err("git returned an empty hook path".into());
    }
    let path = PathBuf::from(path);
    Ok(if path.is_absolute() {
        path
    } else {
        repo.join(path)
    })
}

fn crontab_report(home: &Path) -> (Value, Vec<Value>) {
    match crontab_decision(home) {
        CrontabDecision::Read => match read_crontab(Duration::from_secs(10)) {
            CrontabRead::Text(text) => {
                let entries = crontab_findings(&text);
                (
                    json!({"access":"checked","detail":"read crontab -l","entries":entries.len()}),
                    entries,
                )
            }
            CrontabRead::NoCrontab => (
                json!({"access":"checked","detail":"this account has no crontab","entries":0}),
                Vec::new(),
            ),
            CrontabRead::Unavailable(detail) => (
                json!({"access":"not_checked","detail":detail,"entries":0}),
                Vec::new(),
            ),
        },
        CrontabDecision::Skip(detail) => (
            json!({"access":"not_applicable","detail":detail,"entries":0}),
            Vec::new(),
        ),
        CrontabDecision::Unknown(detail) => (
            json!({"access":"not_checked","detail":detail,"entries":0}),
            Vec::new(),
        ),
    }
}

enum CrontabDecision {
    Read,
    Skip(&'static str),
    Unknown(String),
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn crontab_decision(_home: &Path) -> CrontabDecision {
    CrontabDecision::Skip("this platform has no user crontab database")
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn crontab_decision(home: &Path) -> CrontabDecision {
    match account_home() {
        Ok(account) if same_path(&account, home) => CrontabDecision::Read,
        Ok(_) => CrontabDecision::Skip(
            "this home is not the account home, so the account crontab was not read",
        ),
        Err(detail) => CrontabDecision::Unknown(detail),
    }
}

enum CrontabRead {
    Text(String),
    NoCrontab,
    Unavailable(String),
}

fn read_crontab(timeout: Duration) -> CrontabRead {
    match command_output("crontab", &["-l"], timeout) {
        CommandOutput::Success(output) if output.status.success() => {
            match String::from_utf8(output.stdout) {
                Ok(text) => CrontabRead::Text(text),
                Err(_) => CrontabRead::Unavailable("crontab output is not UTF-8".into()),
            }
        }
        CommandOutput::Success(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            if stderr.to_ascii_lowercase().contains("no crontab") {
                CrontabRead::NoCrontab
            } else {
                CrontabRead::Unavailable(format!(
                    "crontab -l exited {}: {}",
                    output.status,
                    stderr.trim()
                ))
            }
        }
        CommandOutput::Missing => CrontabRead::Unavailable("crontab command is unavailable".into()),
        CommandOutput::TimedOut(detail) => CrontabRead::Unavailable(detail),
        CommandOutput::Failed(detail) => CrontabRead::Unavailable(detail),
    }
}

fn same_path(left: &Path, right: &Path) -> bool {
    match (fs::canonicalize(left), fs::canonicalize(right)) {
        (Ok(left), Ok(right)) => left == right,
        _ => left == right,
    }
}

enum Record {
    Missing,
    Symlink,
    Directory,
    TooBig(String),
    NotUtf8(String),
    Error(String),
    Text(String),
}

fn read_record(path: &Path) -> Record {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Record::Missing,
        Err(error) => Record::Error(error.to_string()),
        Ok(metadata) if metadata.file_type().is_symlink() => Record::Symlink,
        Ok(metadata) if metadata.is_dir() => Record::Directory,
        Ok(metadata) if metadata.len() > READ_LIMIT => Record::TooBig(format!(
            "{} exceeds 1 MiB and was not fully read",
            path.display()
        )),
        Ok(_) => match fs::read(path) {
            Ok(bytes) => match String::from_utf8(bytes) {
                Ok(text) => Record::Text(text),
                Err(_) => Record::NotUtf8(format!("{} is not UTF-8", path.display())),
            },
            Err(error) => Record::Error(error.to_string()),
        },
    }
}
