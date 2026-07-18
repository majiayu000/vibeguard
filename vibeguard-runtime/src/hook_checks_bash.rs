use regex::Regex;
use serde_json::{Value, json};
use std::io::{self, Read};

use crate::hook_checks_common::{nested_str, truncate_chars};
use crate::pkg_rewrite::rewrite_command;

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

const INVALID_INPUT_LOG_REASON: &str = "invalid Bash hook input JSON; fail-closed";
const INVALID_INPUT_REASON: &str = "VIBEGUARD interception: invalid Bash hook input JSON; fail-closed because tool_input.command could not be parsed.";
const DOC_WARNING_CONTEXT: &str = "VIBEGUARD Warning: Creation of non-standard .md file detected. Only README/CLAUDE/CONTRIBUTING/CHANGELOG/LICENSE/SKILL.md is allowed to be created. Please confirm the file purpose if necessary.";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum BashDecision {
    Empty,
    Pass {
        command: String,
        precommit: bool,
    },
    Block {
        log_reason: String,
        detail: String,
        output: String,
    },
    Warn {
        log_reason: String,
        detail: String,
        output: String,
    },
    Correction {
        log_reason: String,
        detail: String,
        command: String,
        corrected: String,
        output: String,
    },
}

#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BashDecisionKind {
    Empty,
    Pass,
    Block,
    Warn,
    Correction,
}

impl BashDecision {
    #[allow(dead_code)]
    fn kind(&self) -> BashDecisionKind {
        match self {
            BashDecision::Empty => BashDecisionKind::Empty,
            BashDecision::Pass { .. } => BashDecisionKind::Pass,
            BashDecision::Block { .. } => BashDecisionKind::Block,
            BashDecision::Warn { .. } => BashDecisionKind::Warn,
            BashDecision::Correction { .. } => BashDecisionKind::Correction,
        }
    }
}

pub fn pre_bash_check(args: &[String]) -> Result {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime pre-bash-check <vibeguard-root>".into());
    }
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let decision = classify_input(&input, &args[0]);
    emit_decision(&decision)?;
    Ok(())
}

fn emit_decision(decision: &BashDecision) -> Result {
    match decision {
        BashDecision::Empty => {
            println!("EMPTY");
            println!("{{}}");
        }
        BashDecision::Pass { command, precommit } => {
            println!("PASS");
            println!(
                "{}",
                serde_json::to_string(&json!({
                    "command": command,
                    "precommit": precommit,
                }))?
            );
        }
        BashDecision::Block {
            log_reason,
            detail,
            output,
        } => {
            println!("BLOCK");
            println!(
                "{}",
                serde_json::to_string(&json!({
                    "log_reason": log_reason,
                    "detail": detail,
                    "output": output,
                }))?
            );
        }
        BashDecision::Warn {
            log_reason,
            detail,
            output,
        } => {
            println!("WARN");
            println!(
                "{}",
                serde_json::to_string(&json!({
                    "log_reason": log_reason,
                    "detail": detail,
                    "output": output,
                }))?
            );
        }
        BashDecision::Correction {
            log_reason,
            detail,
            command,
            corrected,
            output,
        } => {
            println!("CORRECTION");
            println!(
                "{}",
                serde_json::to_string(&json!({
                    "log_reason": log_reason,
                    "detail": detail,
                    "command": command,
                    "corrected": corrected,
                    "output": output,
                }))?
            );
        }
    }
    Ok(())
}

pub(crate) fn evaluate_pre_bash_input(input: &str, vibeguard_root: &str) -> BashDecision {
    classify_input(input, vibeguard_root)
}

fn classify_input(input: &str, vibeguard_root: &str) -> BashDecision {
    let Ok(data) = serde_json::from_str::<Value>(input) else {
        return invalid_input_block();
    };
    let Some(command) = nested_str(&data, "tool_input.command") else {
        return invalid_input_block();
    };
    if command.is_empty() {
        return BashDecision::Empty;
    }

    classify_command(&command, vibeguard_root)
}

fn invalid_input_block() -> BashDecision {
    BashDecision::Block {
        log_reason: INVALID_INPUT_LOG_REASON.to_string(),
        detail: String::new(),
        output: native_output(json!({
            "decision": "block",
            "reason": INVALID_INPUT_REASON,
        })),
    }
}

fn classify_command(command: &str, vibeguard_root: &str) -> BashDecision {
    let command_no_heredoc = strip_heredoc_bodies(command);
    let command_stripped = strip_quoted_content(&command_no_heredoc);
    let command_path_scan = command_no_heredoc.replace(['"', '\''], "");
    let command_stripped_with_dot =
        strip_quoted_content(&normalize_quoted_dot(&command_no_heredoc));

    if regex_is_match(
        r"git\s+(checkout|restore)\s+\.\s*(;|&&|\|\||[<>]|$)",
        &command_stripped_with_dot,
    ) {
        return block_decision(
            &format!(
                "Disable git checkout/restore. (discard all changes in batches). Alternatives: git checkout -- <specific file> specifies the files to be discarded; git stash temporarily stores all changes (recoverable); git diff first checks the changes before deciding.{}",
                authorized_discard_hint(vibeguard_root)
            ),
            command,
        );
    }

    if regex_is_match(r"git\s+clean\s+.*-f", &command_stripped) {
        return block_decision(
            &format!(
                "Disable git clean -f (untracked files are permanently deleted and cannot be recovered). Alternatives: git clean -n (dry run preview) to see what will be deleted first; git stash --include-untracked to temporarily store untracked files; manually rm to specify files.{}",
                authorized_discard_hint(vibeguard_root)
            ),
            command,
        );
    }

    if has_rm_recursive_force(&command_stripped) && has_dangerous_rm_path(&command_path_scan) {
        return block_decision(
            "Prohibit rm -rf dangerous paths (the root directory, home directory, and system directory are not recoverable). Alternatives: rm -rf <specific deep subdirectory> specifies the exact path; rm -ri interactively confirms; first confirm the target with ls and then delete it.",
            command,
        );
    }

    if is_nonstandard_markdown_write(&command_stripped) {
        return BashDecision::Warn {
            log_reason: "Non-standard .md file".to_string(),
            detail: command.to_string(),
            output: native_output(json!({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "additionalContext": DOC_WARNING_CONTEXT,
                }
            })),
        };
    }

    if let Some(corrected) = rewrite_command(command.trim()) {
        return BashDecision::Correction {
            log_reason: "package manager auto-rewrite".to_string(),
            detail: format!("{} → {}", truncate_chars(command, 120), corrected),
            command: command.to_string(),
            corrected: corrected.clone(),
            output: native_output(json!({
                "decision": "allow",
                "updatedInput": {
                    "command": corrected,
                }
            })),
        };
    }

    BashDecision::Pass {
        precommit: should_run_precommit(&command_stripped, command),
        command: command.to_string(),
    }
}

#[allow(dead_code)]
pub(crate) fn classify_command_kind(command: &str, vibeguard_root: &str) -> BashDecisionKind {
    classify_command(command, vibeguard_root).kind()
}

fn block_decision(reason: &str, command: &str) -> BashDecision {
    BashDecision::Block {
        log_reason: reason.to_string(),
        detail: command.to_string(),
        output: native_output(json!({
            "decision": "block",
            "reason": format!("VIBEGUARD interception: {reason}"),
        })),
    }
}

fn native_output(value: Value) -> String {
    serde_json::to_string_pretty(&value).unwrap_or_else(|_| "{}".to_string())
}

fn authorized_discard_hint(vibeguard_root: &str) -> String {
    format!(
        " To perform an audited cleanup, run: python3 \"{}/scripts/authorized-discard.py\" --plan, then rerun with --confirm \"discard listed changes\" after reviewing the enumerated paths.",
        vibeguard_root
    )
}

fn strip_heredoc_bodies(command: &str) -> String {
    let Ok(heredoc) = Regex::new(r#"<<(?P<dash>-?)\s*(['"]?)(?P<tag>[A-Za-z0-9_]+)['"]?"#) else {
        return command.to_string();
    };
    let mut terminator: Option<String> = None;
    let mut strip_tabs = false;
    let mut out = String::new();

    for line in command.split_inclusive('\n') {
        if let Some(expected) = &terminator {
            let mut candidate = line.trim_end_matches(['\r', '\n']).to_string();
            if strip_tabs {
                candidate = candidate.trim_start_matches('\t').to_string();
            }
            if candidate == *expected {
                terminator = None;
                strip_tabs = false;
            }
            continue;
        }

        out.push_str(line);
        if let Some(captures) = heredoc.captures(line) {
            terminator = captures.name("tag").map(|m| m.as_str().to_string());
            strip_tabs = captures.name("dash").is_some_and(|m| m.as_str() == "-");
        }
    }

    out
}

fn strip_quoted_content(command: &str) -> String {
    let Ok(double_quoted) = Regex::new(r#""[^"]*""#) else {
        return command.to_string();
    };
    let Ok(single_quoted) = Regex::new(r#"'[^']*'"#) else {
        return command.to_string();
    };
    let stripped = double_quoted.replace_all(command, r#""""#);
    single_quoted.replace_all(&stripped, "''").to_string()
}

fn normalize_quoted_dot(command: &str) -> String {
    command.replace("\".\"", ".").replace("'.'", ".")
}

fn has_rm_recursive_force(command_stripped: &str) -> bool {
    regex_is_match(
        r"(?m)(^|[;&|]\s*)(sudo\s+)?(\\?rm)\s+((-[A-Za-z]*([rR][A-Za-z]*f|f[A-Za-z]*[rR]))|(--(recursive|force)\s+--(recursive|force)))(\s|$)",
        command_stripped,
    )
}

fn has_dangerous_rm_path(command_path_scan: &str) -> bool {
    [
        r"\s/(\s|[;|&]|$)",
        r"\s~(\s|[;|&/]|$)",
        r"\$HOME",
        r"\s/Users(/[^/\s;|&]*)?(\s|[;|&]|$)",
        r"\s/home(/[^/\s;|&]*)?(\s|[;|&]|$)",
        r"\s/(etc|var|usr|bin|sbin|opt|System|Library)(\s|[;|&/]|$)",
    ]
    .iter()
    .any(|pattern| regex_is_match(pattern, command_path_scan))
}

fn is_nonstandard_markdown_write(command_stripped: &str) -> bool {
    if !regex_is_match(r"(cat|echo|printf|tee)\s.*>.*\.md\b", command_stripped) {
        return false;
    }
    if regex_is_match(
        r">.*(/tmp/|/var/|/proc/|\$TMPDIR|\$TEMP|mktemp)",
        command_stripped,
    ) {
        return false;
    }
    !regex_is_match(
        r"(?i)(README|CLAUDE|CONTRIBUTING|CHANGELOG|LICENSE|SKILL)\.md",
        command_stripped,
    )
}

fn should_run_precommit(command_stripped: &str, command: &str) -> bool {
    regex_is_match(r"git\s+commit\b", command_stripped)
        && !regex_is_match(r"VIBEGUARD_SKIP_PRECOMMIT=1", command)
}

fn regex_is_match(pattern: &str, text: &str) -> bool {
    Regex::new(pattern).is_ok_and(|regex| regex.is_match(text))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn classify(command: &str) -> BashDecision {
        classify_command(command, "/repo")
    }

    fn is_block(command: &str) -> bool {
        matches!(classify(command), BashDecision::Block { .. })
    }

    #[test]
    fn invalid_and_empty_inputs_have_explicit_decisions() {
        assert!(matches!(
            classify_input("{", "/repo"),
            BashDecision::Block { .. }
        ));
        assert!(matches!(
            classify_input(r#"{"tool_input":{}}"#, "/repo"),
            BashDecision::Block { .. }
        ));
        assert_eq!(
            classify_input(r#"{"tool_input":{"command":""}}"#, "/repo"),
            BashDecision::Empty
        );
    }

    #[test]
    fn checkout_restore_dot_variants_block() {
        for command in [
            "git checkout .",
            "git checkout \".\"",
            "git checkout '.'",
            "git restore \".\"",
            "GIT_TRACE=1 git checkout \".\"",
            "env GIT_TRACE=1 git restore \".\"",
            "command git checkout \".\"",
            "echo y | git checkout \".\"",
        ] {
            assert!(is_block(command), "{command}");
        }
    }

    #[test]
    fn quoted_text_and_heredoc_bodies_do_not_false_positive() {
        for command in [
            "echo \"git checkout .\"",
            "printf \"%s\\n\" \"git restore .\"",
            "git commit -m \"repro: git checkout .\"",
            "git commit -m \"docs; git checkout .\"",
            "echo \"note && git restore .\"",
            "cat <<'EOF'\ngit checkout .\nrm -rf /\nEOF",
            "cat <<-EOF\n\tgit checkout .\n\tEOF",
            "cat <<123\ngit checkout .\nrm -rf /\n123",
        ] {
            assert!(!is_block(command), "{command}");
        }
    }

    #[test]
    fn real_command_before_heredoc_still_blocks() {
        assert!(is_block("git checkout . <<'EOF'\nnot command text\nEOF"));
    }

    #[test]
    fn git_clean_and_dangerous_rm_block() {
        for command in [
            "git clean -fd",
            "rm -rf /",
            "rm -rf ~/",
            "rm -rf /Users/foo",
            "rm --recursive --force /home/me",
            "sudo rm -Rf /etc",
        ] {
            assert!(is_block(command), "{command}");
        }
        assert!(!is_block("rm -rf ./node_modules"));
    }

    #[test]
    fn markdown_write_warns_without_blocking() {
        assert!(matches!(
            classify("printf x > notes.md"),
            BashDecision::Warn { .. }
        ));
        assert!(matches!(
            classify("printf x > README.md"),
            BashDecision::Pass { .. }
        ));
    }

    #[test]
    fn package_rewrite_and_precommit_signals_are_reported() {
        assert!(matches!(
            classify("npm install"),
            BashDecision::Correction { .. }
        ));
        assert!(matches!(
            classify("  npm install  "),
            BashDecision::Correction { .. }
        ));
        assert!(matches!(
            classify("git commit -m \"ok\""),
            BashDecision::Pass {
                precommit: true,
                ..
            }
        ));
        assert!(matches!(
            classify("VIBEGUARD_SKIP_PRECOMMIT=1 git commit -m ok"),
            BashDecision::Pass {
                precommit: false,
                ..
            }
        ));
    }
}
