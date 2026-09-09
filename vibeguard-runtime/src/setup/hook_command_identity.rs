use crate::setup::support::{basename, shell_split};
use std::collections::BTreeSet;

pub(crate) fn command_invokes_script(command: &str, script: &str, wrapper_name: &str) -> bool {
    let parts = shell_split(command);
    parts_invokes_script(&parts, script, wrapper_name)
}

pub(crate) fn managed_script_from_command<'a>(
    command: &str,
    managed_scripts: &'a BTreeSet<String>,
    wrapper_name: &str,
) -> Option<&'a str> {
    let parts = shell_split(command);
    for (index, token) in parts.iter().enumerate() {
        if basename(token) != wrapper_name || !wrapper_is_invoked(&parts, index) {
            continue;
        }
        let Some(next) = parts.get(index + 1) else {
            continue;
        };
        if let Some(script) = managed_scripts.get(basename(next)) {
            return Some(script);
        }
    }
    for (index, token) in parts.iter().enumerate() {
        let token_base = basename(token);
        let Some(script) = managed_scripts.get(token_base) else {
            continue;
        };
        if looks_like_direct_script(&parts, index) {
            return Some(script);
        }
    }
    None
}

pub(crate) fn command_is_managed(
    managed_scripts: &BTreeSet<String>,
    command: &str,
    wrapper_name: &str,
) -> bool {
    managed_script_from_command(command, managed_scripts, wrapper_name).is_some()
}

fn parts_invokes_script(parts: &[String], script: &str, wrapper_name: &str) -> bool {
    for (index, token) in parts.iter().enumerate() {
        if basename(token) == wrapper_name
            && wrapper_is_invoked(parts, index)
            && parts
                .get(index + 1)
                .is_some_and(|next| basename(next) == script)
        {
            return true;
        }
    }
    parts
        .iter()
        .enumerate()
        .any(|(index, token)| basename(token) == script && looks_like_direct_script(parts, index))
}

fn looks_like_direct_script(parts: &[String], index: usize) -> bool {
    let token = &parts[index];
    token.contains('/')
        || index
            .checked_sub(1)
            .is_some_and(|previous| is_shell(&parts[previous]))
        || (index == 0 && token.ends_with(".sh"))
}

fn wrapper_is_invoked(parts: &[String], index: usize) -> bool {
    if index == 0 {
        return true;
    }
    if is_shell(&parts[index - 1]) {
        return true;
    }
    if index >= 2
        && parts[index - 1].starts_with('-')
        && !shell_option_uses_command_string(&parts[index - 1])
        && is_shell(&parts[index - 2])
    {
        return true;
    }
    if env_invokes_token(parts, index) {
        return true;
    }
    false
}

fn env_invokes_token(parts: &[String], index: usize) -> bool {
    if parts.first().map(|token| basename(token)) != Some("env") {
        return false;
    }
    let mut cursor = 1;
    while cursor < index {
        let token = &parts[cursor];
        if token == "--" {
            cursor += 1;
            break;
        }
        if token.starts_with('-') {
            if env_option_takes_value(token) && cursor + 1 < index {
                cursor += 2;
            } else {
                cursor += 1;
            }
            continue;
        }
        if is_env_assignment(token) {
            cursor += 1;
            continue;
        }
        return false;
    }
    cursor == index
}

fn shell_option_uses_command_string(token: &str) -> bool {
    if token == "--" {
        return false;
    }
    if token == "--command" {
        return true;
    }
    if token.starts_with("--") {
        return false;
    }
    token.trim_start_matches('-').contains('c')
}

fn env_option_takes_value(token: &str) -> bool {
    matches!(
        token,
        "-u" | "--unset" | "-C" | "--chdir" | "-S" | "--split-string"
    )
}

fn is_env_assignment(token: &str) -> bool {
    token.contains('=') && !token.starts_with('=')
}

fn is_shell(token: &str) -> bool {
    matches!(basename(token), "bash" | "sh" | "zsh")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn claude_managed() -> BTreeSet<String> {
        BTreeSet::from(["pre-bash-guard.sh".to_string()])
    }

    fn codex_managed() -> BTreeSet<String> {
        BTreeSet::from([
            "vibeguard-pre-bash-guard.sh".to_string(),
            "vibeguard-post-build-check.sh".to_string(),
        ])
    }

    #[test]
    fn env_prefix_counts_as_wrapper_invocation() {
        let command = "env VIBEGUARD_FOO=1 /tmp/.vibeguard/run-hook.sh pre-bash-guard.sh";

        assert!(command_invokes_script(
            command,
            "pre-bash-guard.sh",
            "run-hook.sh"
        ));
        assert_eq!(
            managed_script_from_command(command, &claude_managed(), "run-hook.sh"),
            Some("pre-bash-guard.sh")
        );
    }

    #[test]
    fn env_wrapped_tool_argument_does_not_count_as_wrapper_invocation() {
        let command = "env node /custom/audit.js /tmp/.vibeguard/run-hook.sh pre-bash-guard.sh";

        assert!(!command_invokes_script(
            command,
            "pre-bash-guard.sh",
            "run-hook.sh"
        ));
        assert_eq!(
            managed_script_from_command(command, &claude_managed(), "run-hook.sh"),
            None
        );
    }

    #[test]
    fn shell_c_command_string_does_not_count_as_wrapper_invocation() {
        let command = "bash -c /tmp/.vibeguard/run-hook.sh pre-bash-guard.sh";

        assert!(!command_invokes_script(
            command,
            "pre-bash-guard.sh",
            "run-hook.sh"
        ));
        assert_eq!(
            managed_script_from_command(command, &claude_managed(), "run-hook.sh"),
            None
        );
    }

    #[test]
    fn shell_non_command_option_counts_as_wrapper_invocation() {
        let command = "bash -e /tmp/.vibeguard/run-hook.sh pre-bash-guard.sh";

        assert!(command_invokes_script(
            command,
            "pre-bash-guard.sh",
            "run-hook.sh"
        ));
        assert_eq!(
            managed_script_from_command(command, &claude_managed(), "run-hook.sh"),
            Some("pre-bash-guard.sh")
        );
    }

    #[test]
    fn codex_wrapper_and_direct_script_are_managed() {
        assert!(command_is_managed(
            &codex_managed(),
            "bash /tmp/run-hook-codex.sh vibeguard-pre-bash-guard.sh",
            "run-hook-codex.sh"
        ));
        assert!(command_is_managed(
            &codex_managed(),
            "env VIBEGUARD_PROFILE=full bash /tmp/run-hook-codex.sh vibeguard-post-build-check.sh",
            "run-hook-codex.sh"
        ));
        assert!(command_is_managed(
            &codex_managed(),
            "bash ~/.vibeguard/installed/hooks/vibeguard-post-build-check.sh",
            "run-hook-codex.sh"
        ));
    }

    #[test]
    fn codex_argument_only_mention_is_not_managed() {
        assert!(!command_is_managed(
            &codex_managed(),
            "node /custom/audit.js vibeguard-post-build-check.sh",
            "run-hook-codex.sh"
        ));
        assert!(!command_is_managed(
            &codex_managed(),
            "python /tmp/user_hook.py --label vibeguard-pre-bash-guard.sh",
            "run-hook-codex.sh"
        ));
        assert!(!command_is_managed(
            &codex_managed(),
            "env node /custom/audit.js /tmp/run-hook-codex.sh vibeguard-post-build-check.sh",
            "run-hook-codex.sh"
        ));
    }

    #[test]
    fn shell_launched_script_argument_is_not_managed() {
        let managed = BTreeSet::from(["post-build-check.sh".to_string()]);
        assert!(!command_is_managed(
            &managed,
            "bash /custom/audit.sh post-build-check.sh",
            "run-hook.sh"
        ));
        assert!(!command_is_managed(
            &managed,
            "sh /tmp/user-hook.sh --label post-build-check.sh",
            "run-hook.sh"
        ));
        assert!(command_is_managed(
            &managed,
            "bash /tmp/.vibeguard/run-hook.sh post-build-check.sh",
            "run-hook.sh"
        ));
        assert!(command_is_managed(
            &managed,
            "bash ~/.vibeguard/installed/hooks/post-build-check.sh",
            "run-hook.sh"
        ));
    }
}
