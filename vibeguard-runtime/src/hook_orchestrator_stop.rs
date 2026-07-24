use serde_json::Value;
use std::env;
use std::path::Path;
use std::process::Command;
use std::time::Instant;

use crate::event_schema::{decision, field, status, tool};
use crate::git_root::current_git_root_by_marker;
use crate::hook_checks_common::{first_detail_path, is_source_path, is_test_path};
use crate::hook_checks_history::read_tail_lines;
use crate::hook_orchestrator::{HookKind, Result, append_hook_event, elapsed_ms};
use crate::hook_orchestrator_context::RuntimeContext;
use crate::wrapper_env::env_nonempty;

const STOP_VERIFY_HISTORY_LINES: usize = 500;
const STOP_VERIFY_REASON_PREFIX: &str = "[W-16] stop without verification evidence";

pub(crate) fn run(input: &str, start: Instant) -> Result {
    let Some(git_root) = current_git_root_by_marker() else {
        return Ok(());
    };
    if stop_is_ci() || stop_hook_active(input) {
        return Ok(());
    }

    let changed_files = changed_source_files();
    let ctx = match RuntimeContext::collect() {
        Ok(ctx) => ctx,
        Err(err) => {
            eprintln!("VIBEGUARD: failed to collect context for stop-guard event: {err}");
            return Ok(());
        }
    };
    detect_unverified_stop(&ctx, &git_root, start)?;
    if changed_files.is_empty() {
        append_hook_event(
            &ctx,
            HookKind::Stop,
            decision::PASS,
            status::PASS,
            "",
            "",
            elapsed_ms(start),
        )?;
        return Ok(());
    }

    let detail = stop_changed_detail(&changed_files);
    append_hook_event(
        &ctx,
        HookKind::Stop,
        decision::GATE,
        status::GATE,
        &format!("uncommitted source changes: {} files", changed_files.len()),
        &detail,
        elapsed_ms(start),
    )?;
    Ok(())
}

/// Issue #674: sessions that edit source files but never run a verification
/// command end without any W-03/W-16 evidence. Advisory-only (`warn`,
/// exit stays 0); precision is trackable via the reason prefix.
/// Downgrade path (U-32): VIBEGUARD_SUPPRESS_STOP_VERIFY=1 skips the check.
fn detect_unverified_stop(ctx: &RuntimeContext, git_root: &Path, start: Instant) -> Result {
    if env::var("VIBEGUARD_SUPPRESS_STOP_VERIFY").as_deref() == Ok("1") {
        return Ok(());
    }
    let Some(suggested) = toolchain_verify_command(git_root) else {
        return Ok(());
    };
    let log_file = ctx.log_file.to_string_lossy();
    let Ok(lines) = read_tail_lines(&log_file, STOP_VERIFY_HISTORY_LINES) else {
        return Ok(());
    };
    let mut edited: Vec<String> = Vec::new();
    let mut verified = false;
    for line in lines.lines() {
        let Ok(event) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        if event.get(field::SESSION).and_then(Value::as_str) != Some(ctx.session_id.as_str()) {
            continue;
        }
        let hook_name = event.get(field::HOOK).and_then(Value::as_str).unwrap_or("");
        match hook_name {
            "pre-edit-guard" | "pre-write-guard" => {
                let path = first_detail_path(&event);
                if is_source_path(path)
                    && !is_test_path(path)
                    && !path.contains("/generated/")
                    && !edited.iter().any(|seen| seen == path)
                {
                    edited.push(path.to_string());
                }
            }
            "pre-bash-guard"
                if event.get(field::TOOL).and_then(Value::as_str) == Some(tool::BASH)
                    && event
                        .get(field::DETAIL)
                        .and_then(Value::as_str)
                        .is_some_and(is_verification_command) =>
            {
                verified = true;
            }
            _ => {}
        }
    }
    if edited.is_empty() || verified {
        return Ok(());
    }

    let shown = edited
        .iter()
        .take(5)
        .map(String::as_str)
        .collect::<Vec<_>>()
        .join(" ");
    println!(
        "VIBEGUARD [W-16] [advisory] [session] OBSERVATION: this session edited {} source file(s) ({shown}) but ran no verification command\nFIX: run `{suggested}` (or the project test command) and re-check the result before treating the change as done\nDO NOT: claim completion from memory — W-16 requires fresh command output\nESCAPE: set VIBEGUARD_SUPPRESS_STOP_VERIFY=1 for intentionally exploratory sessions",
        edited.len()
    );
    append_hook_event(
        ctx,
        HookKind::Stop,
        decision::WARN,
        status::WARN,
        &format!(
            "{STOP_VERIFY_REASON_PREFIX}: {} source files edited",
            edited.len()
        ),
        &format!("{shown} ||suggest={suggested}"),
        elapsed_ms(start),
    )
}

/// Detect the repo toolchain; None means verification is not meaningful here.
fn toolchain_verify_command(git_root: &Path) -> Option<&'static str> {
    if git_root.join("Cargo.toml").is_file() {
        Some("cargo test")
    } else if git_root.join("go.mod").is_file() {
        Some("go test ./...")
    } else if git_root.join("pyproject.toml").is_file() || git_root.join("setup.py").is_file() {
        Some("pytest")
    } else if git_root.join("package.json").is_file() {
        Some("npm test")
    } else {
        None
    }
}

fn is_verification_command(command: &str) -> bool {
    const PATTERNS: [&str; 33] = [
        "cargo test",
        "cargo check",
        "cargo clippy",
        "cargo build",
        "cargo nextest",
        "go test",
        "go build",
        "go vet",
        "pytest",
        "python -m pytest",
        "python3 -m pytest",
        "uv run pytest",
        "uv run ruff",
        "uv run mypy",
        "ruff check",
        "mypy",
        "npm test",
        "npm run build",
        "npm run lint",
        "pnpm test",
        "pnpm build",
        "yarn test",
        "yarn build",
        "npx tsc",
        "tsc --noEmit",
        "make test",
        "make check",
        "make build",
        "just test",
        "just check",
        "bazel test",
        "vitest",
        "jest",
    ];
    PATTERNS.iter().any(|pattern| command.contains(pattern))
        || command.contains("gradle test")
        || command.contains("gradle build")
        || command.contains("mvn test")
        || command.contains("mvn verify")
        || command.contains("bash tests/")
        || command.split_whitespace().any(|token| token == "tox")
}

fn stop_is_ci() -> bool {
    fn truthy_env(name: &str) -> bool {
        matches!(
            env::var(name).as_deref(),
            Ok("true" | "True" | "TRUE" | "1" | "yes" | "Yes" | "YES")
        )
    }
    truthy_env("CI")
        || truthy_env("GITHUB_ACTIONS")
        || truthy_env("TRAVIS")
        || truthy_env("CIRCLECI")
        || env_nonempty("JENKINS_URL").is_some()
        || truthy_env("GITLAB_CI")
        || truthy_env("TF_BUILD")
}

fn stop_hook_active(input: &str) -> bool {
    serde_json::from_str::<Value>(input)
        .ok()
        .and_then(|data| data.get("stop_hook_active").and_then(Value::as_bool))
        .unwrap_or(false)
}

fn changed_source_files() -> Vec<String> {
    let names = git_diff_names(&["diff", "--name-only", "HEAD"])
        .or_else(|| git_diff_names(&["diff", "--name-only", "--cached"]))
        .unwrap_or_default();
    let mut files = names
        .into_iter()
        .filter(|file| !file.is_empty() && is_source_path(file))
        .collect::<Vec<_>>();
    files.sort();
    files.dedup();
    files
}

fn git_diff_names(args: &[&str]) -> Option<Vec<String>> {
    let output = Command::new("git")
        .args(args)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .map(str::to_string)
            .collect(),
    )
}

fn stop_changed_detail(files: &[String]) -> String {
    if files.is_empty() {
        return String::new();
    }
    let mut detail = files
        .iter()
        .take(5)
        .map(String::as_str)
        .collect::<Vec<_>>()
        .join(" ");
    detail.push(' ');
    detail
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verification_commands_match_issue_674_pattern_set() {
        for command in [
            "cargo test -q",
            "cargo check",
            "go test ./...",
            "uv run pytest tests/",
            "npx tsc --noEmit",
            "bash tests/test_hooks.sh",
            "make check",
            "tox",
        ] {
            assert!(is_verification_command(command), "{command} should verify");
        }
        for command in [
            "git status",
            "ls -la",
            "grep -rn pattern src/",
            "cat Cargo.toml",
            "detox run",
        ] {
            assert!(
                !is_verification_command(command),
                "{command} should not verify"
            );
        }
    }

    #[test]
    fn toolchain_detection_requires_a_known_manifest() {
        let root = std::env::temp_dir().join(format!("vg-stop-toolchain-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        assert_eq!(toolchain_verify_command(&root), None);
        std::fs::write(root.join("Cargo.toml"), "[package]\n").unwrap();
        assert_eq!(toolchain_verify_command(&root), Some("cargo test"));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn stop_hook_active_only_accepts_true_boolean() {
        assert!(stop_hook_active(r#"{"stop_hook_active":true}"#));
        assert!(!stop_hook_active(r#"{"stop_hook_active":false}"#));
        assert!(!stop_hook_active(r#"{"stop_hook_active":"true"}"#));
        assert!(!stop_hook_active("{"));
    }

    #[test]
    fn stop_changed_detail_includes_first_five_files_with_trailing_space() {
        let files = vec![
            "a.rs".to_string(),
            "b.rs".to_string(),
            "c.rs".to_string(),
            "d.rs".to_string(),
            "e.rs".to_string(),
            "f.rs".to_string(),
        ];

        assert_eq!(stop_changed_detail(&files), "a.rs b.rs c.rs d.rs e.rs ");
        assert_eq!(stop_changed_detail(&[]), "");
    }
}
