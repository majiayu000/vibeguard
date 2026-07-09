use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

use crate::event_schema::{decision, status};
use crate::hook_checks_bash::{BashDecision, evaluate_pre_bash_input};
use crate::hook_checks_common::truncate_chars;
use crate::hook_orchestrator::{
    HookKind, Result, append_hook_event, elapsed_ms, print_policy_decision_kv,
};
use crate::hook_orchestrator_context::RuntimeContext;
use crate::wrapper_env::env_nonempty;

pub(crate) fn run(ctx: &RuntimeContext, input: &str, start: Instant) -> Result {
    let vibeguard_root = vibeguard_root();
    match evaluate_pre_bash_input(input, &vibeguard_root) {
        BashDecision::Empty => {}
        BashDecision::Block {
            log_reason,
            detail,
            output,
        } => {
            append_hook_event(
                ctx,
                HookKind::PreBash,
                decision::BLOCK,
                status::BLOCK,
                &log_reason,
                &detail,
                elapsed_ms(start),
            )?;
            println!("{output}");
        }
        BashDecision::Warn {
            log_reason,
            detail,
            output,
        } => {
            append_hook_event(
                ctx,
                HookKind::PreBash,
                decision::WARN,
                status::WARN,
                &log_reason,
                &detail,
                elapsed_ms(start),
            )?;
            println!("{output}");
        }
        BashDecision::Correction {
            command,
            corrected,
            output,
            ..
        } => {
            let target_tool = corrected.split_whitespace().next().unwrap_or("");
            if !command_available(target_tool) {
                append_hook_event(
                    ctx,
                    HookKind::PreBash,
                    decision::PASS,
                    status::PASS,
                    &format!("pkg-rewrite skipped ({target_tool} not found)"),
                    &truncate_chars(&command, 120),
                    elapsed_ms(start),
                )?;
                return Ok(());
            }
            if corrected.starts_with("uv pip install")
                && env_nonempty("VIRTUAL_ENV").is_none()
                && !Path::new(".venv").is_dir()
            {
                append_hook_event(
                    ctx,
                    HookKind::PreBash,
                    decision::PASS,
                    status::PASS,
                    "pkg-rewrite skipped (no active venv for uv pip)",
                    &truncate_chars(&command, 120),
                    elapsed_ms(start),
                )?;
                return Ok(());
            }
            append_hook_event(
                ctx,
                HookKind::PreBash,
                decision::CORRECTION,
                status::CORRECTION,
                "package manager auto-rewrite",
                &format!("{} → {}", truncate_chars(&command, 120), corrected),
                elapsed_ms(start),
            )?;
            println!("{output}");
        }
        BashDecision::Pass { command, precommit } => {
            if precommit {
                let precommit_script = hook_dir().join("pre-commit-guard.sh");
                if precommit_script.is_file() {
                    let output = Command::new("bash")
                        .arg(&precommit_script)
                        .env("VIBEGUARD_DIR", &vibeguard_root)
                        .output();
                    match output {
                        Ok(output) if output.status.success() => {}
                        Ok(output) => {
                            append_hook_event(
                                ctx,
                                HookKind::PreBash,
                                decision::BLOCK,
                                status::BLOCK,
                                "pre-commit check failed",
                                &command,
                                elapsed_ms(start),
                            )?;
                            let precommit_output = command_output_text(&output);
                            print_policy_decision_kv(
                                "block",
                                &format!(
                                    "VIBEGUARD Pre-Commit 检查失败。请根据上方错误信息修复问题后重新提交。禁止使用环境变量绕过。\n\n{precommit_output}"
                                ),
                            );
                            return Ok(());
                        }
                        Err(err) => {
                            append_hook_event(
                                ctx,
                                HookKind::PreBash,
                                decision::BLOCK,
                                status::BLOCK,
                                "pre-commit check failed",
                                &command,
                                elapsed_ms(start),
                            )?;
                            print_policy_decision_kv(
                                "block",
                                &format!(
                                    "VIBEGUARD Pre-Commit 检查失败。请根据上方错误信息修复问题后重新提交。禁止使用环境变量绕过。\n\n{err}"
                                ),
                            );
                            return Ok(());
                        }
                    }
                }
            }
            append_hook_event(
                ctx,
                HookKind::PreBash,
                decision::PASS,
                status::PASS,
                "",
                &command,
                elapsed_ms(start),
            )?;
        }
    }
    Ok(())
}

fn vibeguard_root() -> String {
    if let Some(root) = env_nonempty("VIBEGUARD_DIR") {
        return root;
    }
    if let Some(hook_dir) = env_nonempty("VIBEGUARD_HOOK_DIR").map(PathBuf::from)
        && let Some(parent) = hook_dir.parent()
    {
        return parent.to_string_lossy().to_string();
    }
    env::current_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .to_string_lossy()
        .to_string()
}

fn hook_dir() -> PathBuf {
    env_nonempty("VIBEGUARD_HOOK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
}

fn command_available(tool: &str) -> bool {
    if tool.is_empty() {
        return false;
    }
    if tool.contains('/') || tool.contains('\\') {
        return is_executable_file(Path::new(tool));
    }
    let Some(path_var) = env::var_os("PATH") else {
        return false;
    };
    env::split_paths(&path_var).any(|dir| is_executable_file(&dir.join(tool)))
}

fn is_executable_file(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::metadata(path)
            .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn command_output_text(output: &std::process::Output) -> String {
    let mut text = String::new();
    text.push_str(&String::from_utf8_lossy(&output.stdout));
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_available_accepts_current_executable_path() {
        let current_exe = env::current_exe().expect("current test executable path");

        assert!(!command_available(""));
        assert!(command_available(&current_exe.to_string_lossy()));
    }
}
