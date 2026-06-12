use crate::setup_support::{basename, shell_split};
use std::collections::BTreeSet;

pub(super) fn command_invokes_script(command: &str, script: &str) -> bool {
    let parts = shell_split(command);
    parts_invokes_script(&parts, script)
}

pub(super) fn managed_script_from_command<'a>(
    command: &str,
    managed_scripts: &'a BTreeSet<String>,
) -> Option<&'a str> {
    let parts = shell_split(command);
    for (index, token) in parts.iter().enumerate() {
        if basename(token) != "run-hook.sh" || !wrapper_is_invoked(&parts, index) {
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
        if looks_like_direct_script(&parts, index) || shell_invokes_wrapper(&parts, index) {
            return Some(script);
        }
    }
    None
}

fn parts_invokes_script(parts: &[String], script: &str) -> bool {
    for (index, token) in parts.iter().enumerate() {
        if basename(token) == "run-hook.sh"
            && wrapper_is_invoked(parts, index)
            && parts
                .get(index + 1)
                .is_some_and(|next| basename(next) == script)
        {
            return true;
        }
    }
    parts.iter().enumerate().any(|(index, token)| {
        basename(token) == script
            && (looks_like_direct_script(parts, index) || shell_invokes_wrapper(parts, index))
    })
}

fn looks_like_direct_script(parts: &[String], index: usize) -> bool {
    let token = &parts[index];
    token.contains('/')
        || index
            .checked_sub(1)
            .is_some_and(|previous| is_shell(&parts[previous]))
        || (index == 0 && token.ends_with(".sh"))
}

fn shell_invokes_wrapper(parts: &[String], index: usize) -> bool {
    index >= 2 && is_shell(&parts[index - 2]) && !parts[index - 1].starts_with('-')
}

fn wrapper_is_invoked(parts: &[String], index: usize) -> bool {
    if index == 0 {
        return true;
    }
    if is_shell(&parts[index - 1]) {
        return true;
    }
    if index >= 2 && parts[index - 1].starts_with('-') && is_shell(&parts[index - 2]) {
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

    fn managed_scripts() -> BTreeSet<String> {
        BTreeSet::from(["pre-bash-guard.sh".to_string()])
    }

    #[test]
    fn env_prefix_counts_as_wrapper_invocation() {
        let command = "env VIBEGUARD_FOO=1 /tmp/.vibeguard/run-hook.sh pre-bash-guard.sh";

        assert!(command_invokes_script(command, "pre-bash-guard.sh"));
        assert_eq!(
            managed_script_from_command(command, &managed_scripts()),
            Some("pre-bash-guard.sh")
        );
    }

    #[test]
    fn env_wrapped_tool_argument_does_not_count_as_wrapper_invocation() {
        let command = "env node /custom/audit.js /tmp/.vibeguard/run-hook.sh pre-bash-guard.sh";

        assert!(!command_invokes_script(command, "pre-bash-guard.sh"));
        assert_eq!(
            managed_script_from_command(command, &managed_scripts()),
            None
        );
    }
}
