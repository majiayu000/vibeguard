use serde_json::Value;
use std::env;
use std::process::Command;
use std::time::Instant;

use crate::event_schema::{decision, status};
use crate::git_root::current_git_root_by_marker;
use crate::hook_checks_common::is_source_path;
use crate::hook_orchestrator::{HookKind, Result, append_hook_event, elapsed_ms};
use crate::hook_orchestrator_context::RuntimeContext;
use crate::wrapper_env::env_nonempty;

pub(crate) fn run(input: &str, start: Instant) -> Result {
    if stop_is_ci() || stop_hook_active(input) || current_git_root_by_marker().is_none() {
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
