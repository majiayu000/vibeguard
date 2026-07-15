use std::io;
use std::path::Path;
use std::process::Command;

use crate::hook_checks_common::{
    count_lines, is_allowed_new_file, is_clean_rust_fast_path, is_clean_rust_write_fast_path,
    is_pre_edit_u16_source, is_source_path, is_test_infra_path, is_test_path, nested_str,
    project_u16_limit, read_lossy_file, read_stdin, write_log_event,
};
use crate::hook_checks_history::{
    build_fast_warning_output, post_edit_history_signals, post_edit_history_warnings,
};
use crate::hook_checks_scan::{SameNameScan, find_project_dir, scan_same_name_duplicate};

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PreWriteCheck {
    Malformed,
    Exists {
        file_path: String,
    },
    Allow {
        file_path: String,
    },
    SourceNew {
        file_path: String,
    },
    W12 {
        file_path: String,
    },
    U16Block {
        file_path: String,
        line_count: usize,
        limit: usize,
    },
    U16Warn {
        file_path: String,
        line_count: usize,
        warn_limit: usize,
        limit: usize,
    },
    U16WarnSourceNew {
        file_path: String,
        line_count: usize,
        warn_limit: usize,
        limit: usize,
    },
}

#[derive(Debug, PartialEq, Eq)]
enum MissingFileCandidates {
    Found(Vec<String>),
    Empty,
    LookupFailed(String),
}

pub fn pre_write_check(args: &[String]) -> Result {
    let base_limit = args
        .first()
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(800);
    let warn_limit = args
        .get(1)
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(400);
    let input = read_stdin()?;
    print_pre_write_check(&evaluate_pre_write_input(&input, base_limit, warn_limit));
    Ok(())
}

pub(crate) fn evaluate_pre_write_input(
    input: &str,
    base_limit: usize,
    warn_limit: usize,
) -> PreWriteCheck {
    let Ok(data) = serde_json::from_str::<serde_json::Value>(input) else {
        return PreWriteCheck::Malformed;
    };

    let Some(file_path) = nested_str(&data, "tool_input.file_path") else {
        return PreWriteCheck::Malformed;
    };
    if file_path.is_empty() {
        return PreWriteCheck::Malformed;
    }

    if is_test_infra_path(&file_path) {
        return PreWriteCheck::W12 { file_path };
    }

    let content = nested_str(&data, "tool_input.content").unwrap_or_default();
    let line_count = count_lines(&content);
    let mut u16_advisory = None;
    if is_source_path(&file_path) && !is_test_path(&file_path) {
        let limit = project_u16_limit(&file_path, base_limit);
        if line_count > limit {
            return PreWriteCheck::U16Block {
                file_path,
                line_count,
                limit,
            };
        }
        let advisory_limit = u16_advisory_limit(base_limit, limit, warn_limit);
        if advisory_limit < limit && line_count > advisory_limit {
            u16_advisory = Some((line_count, advisory_limit, limit));
        }
    }

    if Path::new(&file_path).exists() {
        if let Some((line_count, warn_limit, limit)) = u16_advisory {
            return PreWriteCheck::U16Warn {
                file_path,
                line_count,
                warn_limit,
                limit,
            };
        }
        return PreWriteCheck::Exists { file_path };
    }

    if is_allowed_new_file(&file_path) || !is_source_path(&file_path) {
        return PreWriteCheck::Allow { file_path };
    }

    if let Some((line_count, warn_limit, limit)) = u16_advisory {
        return PreWriteCheck::U16WarnSourceNew {
            file_path,
            line_count,
            warn_limit,
            limit,
        };
    }

    PreWriteCheck::SourceNew { file_path }
}

fn print_pre_write_check(check: &PreWriteCheck) {
    match check {
        PreWriteCheck::Malformed => {
            println!("MALFORMED");
        }
        PreWriteCheck::Exists { file_path } => {
            println!("EXISTS");
            println!("{file_path}");
        }
        PreWriteCheck::Allow { file_path } => {
            println!("ALLOW");
            println!("{file_path}");
        }
        PreWriteCheck::SourceNew { file_path } => {
            println!("SOURCE_NEW");
            println!("{file_path}");
        }
        PreWriteCheck::W12 { file_path } => {
            println!("W12");
            println!("{file_path}");
        }
        PreWriteCheck::U16Block {
            file_path,
            line_count,
            limit,
        } => {
            println!("U16_BLOCK");
            println!("{file_path}");
            println!("{line_count}");
            println!("{limit}");
        }
        PreWriteCheck::U16Warn {
            file_path,
            line_count,
            warn_limit,
            limit,
        } => {
            println!("U16_WARN");
            println!("{file_path}");
            println!("{line_count}");
            println!("{warn_limit}");
            println!("{limit}");
        }
        PreWriteCheck::U16WarnSourceNew {
            file_path,
            line_count,
            warn_limit,
            limit,
        } => {
            println!("U16_WARN_SOURCE_NEW");
            println!("{file_path}");
            println!("{line_count}");
            println!("{warn_limit}");
            println!("{limit}");
        }
    }
}

pub fn pre_edit_check(args: &[String]) -> Result {
    if args.len() < 2 {
        return Err(
            "Usage: vibeguard-runtime pre-edit-check <base-limit> [warn-limit] <log-file>".into(),
        );
    }

    let base_limit = args[0].parse::<usize>().unwrap_or(800);
    let (warn_limit, log_file) = if args.len() >= 3 {
        (args[1].parse::<usize>().unwrap_or(400), &args[2])
    } else {
        (400, &args[1])
    };
    let input = read_stdin()?;
    let Ok(data) = serde_json::from_str::<serde_json::Value>(&input) else {
        write_pre_edit_block(
            log_file,
            "Malformed hook input",
            "",
            "VIBEGUARD interception: malformed PreToolUse(Edit) hook input. The edit request could not be validated, so it was blocked instead of being treated as a safe skip.",
        )?;
        return Ok(());
    };

    let file_path = nested_str(&data, "tool_input.file_path").unwrap_or_default();
    let old_string = nested_str(&data, "tool_input.old_string").unwrap_or_default();
    let new_string = nested_str(&data, "tool_input.new_string").unwrap_or_default();
    let replace_all = data
        .get("tool_input")
        .and_then(|v| v.get("replace_all"))
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let patch_line_delta = data
        .get("tool_input")
        .and_then(|v| v.get("vibeguard_line_delta"))
        .and_then(serde_json::Value::as_i64);

    if file_path.is_empty() {
        println!("SKIP");
        return Ok(());
    }

    if is_test_infra_path(&file_path) {
        write_pre_edit_block(
            log_file,
            "Test Infrastructure File Protection (W-12)",
            &file_path,
            &format!(
                "VIBEGUARD W-12 interception: Modification of test infrastructure files - {file_path} is prohibited. AI agents must not modify test framework configuration files such as conftest.py/jest.config/pytest.ini/.coveragerc. Such modifications may cause tests to be bypassed instead of actually fixing code problems. Please fix the code under test rather than manipulating the test framework."
            ),
        )?;
        return Ok(());
    }

    if !Path::new(&file_path).is_file() {
        write_pre_edit_block(
            log_file,
            "File does not exist",
            &file_path,
            &missing_file_reason(&file_path),
        )?;
        return Ok(());
    }

    let content = read_lossy_file(&file_path)?;
    if !old_string.is_empty() && !content.contains(&old_string) {
        write_pre_edit_block(
            log_file,
            "old_string does not exist",
            &file_path,
            "VIBEGUARD interception: old_string does not exist in the file - the AI may have hallucinated the file content. Please use the Read tool to read the file first to confirm that the content to be replaced actually exists.",
        )?;
        return Ok(());
    }

    if is_pre_edit_u16_source(&file_path) && !is_test_path(&file_path) {
        let current_lines = count_lines(&content);
        let estimated = if let Some(delta) = patch_line_delta {
            if delta >= 0 {
                Some(current_lines.saturating_add(delta as usize))
            } else {
                let decrease = usize::try_from(delta.unsigned_abs()).unwrap_or(usize::MAX);
                Some(current_lines.saturating_sub(decrease))
            }
        } else if !old_string.is_empty() && !new_string.is_empty() {
            let old_lines = count_lines(&old_string);
            let new_lines = count_lines(&new_string);
            let occurrences = if replace_all {
                content.matches(&old_string).count()
            } else {
                1
            };
            Some(
                current_lines
                    .saturating_sub(old_lines.saturating_mul(occurrences))
                    .saturating_add(new_lines.saturating_mul(occurrences)),
            )
        } else {
            None
        };

        if let Some(estimated) = estimated {
            let limit = project_u16_limit(&file_path, base_limit);
            if estimated > limit {
                write_pre_edit_block(
                    log_file,
                    &format!("U-16 file size: {estimated} > {limit}"),
                    &file_path,
                    &format!(
                        "VIBEGUARD [U-16] block: this edit would bring {} to ~{estimated} lines (limit: {limit}). Split the file into focused submodules before adding more code. Do NOT proceed with this edit.",
                        Path::new(&file_path)
                            .file_name()
                            .and_then(|s| s.to_str())
                            .unwrap_or(&file_path)
                    ),
                )?;
                return Ok(());
            }
            let advisory_limit = u16_advisory_limit(base_limit, limit, warn_limit);
            if advisory_limit < limit && estimated > advisory_limit {
                let context = u16_advisory_context(
                    &file_path,
                    estimated,
                    advisory_limit,
                    limit,
                    "this edit would leave",
                    false,
                );
                if write_log_event(
                    log_file,
                    "pre-edit-guard",
                    "Edit",
                    "warn",
                    &format!("U-16 file size advisory: {estimated} > {advisory_limit}"),
                    &file_path,
                )
                .is_err()
                {
                    println!("FALLBACK_OUTPUT");
                    println!("{context}");
                    return Ok(());
                }
                println!("FAST_OUTPUT");
                println!("{}", hook_context_json("PreToolUse", &context));
                return Ok(());
            }
        }
    }

    match write_log_event(log_file, "pre-edit-guard", "Edit", "pass", "", &file_path) {
        Ok(()) => println!("FAST_LOGGED"),
        Err(err) => {
            println!("FALLBACK");
            println!("{err}");
        }
    }
    Ok(())
}

pub fn u16_limit(args: &[String]) -> Result {
    if args.len() != 2 {
        return Err("Usage: vibeguard-runtime u16-limit <file-path> <base-limit>".into());
    }
    let base_limit = args[1].parse::<usize>().unwrap_or(800);
    println!("{}", project_u16_limit(&args[0], base_limit));
    Ok(())
}

pub fn test_path_filter(args: &[String]) -> Result {
    if args.len() != 1 || !matches!(args[0].as_str(), "--test" | "--prod") {
        return Err("Usage: vibeguard-runtime test-path-filter <--test|--prod>".into());
    }
    let want_test = args[0] == "--test";
    let input = read_stdin()?;
    for raw_path in input.lines() {
        let path = raw_path.trim_end_matches('\r');
        if !path.is_empty() && is_test_path(path) == want_test {
            println!("{path}");
        }
    }
    Ok(())
}

fn write_pre_edit_block(
    log_file: &str,
    log_reason: &str,
    file_path: &str,
    output_reason: &str,
) -> io::Result<()> {
    let mut visible_reason = output_reason.to_string();
    if let Err(err) = write_log_event(
        log_file,
        "pre-edit-guard",
        "Edit",
        "block",
        log_reason,
        file_path,
    ) {
        eprintln!("VIBEGUARD ERROR: pre-edit block log append failed: {err}");
        visible_reason.push_str("\n\n");
        visible_reason.push_str(&pre_edit_log_failure_message(log_file, &err.to_string()));
    }
    println!("FAST_OUTPUT");
    println!("{}", decision_block_json(&visible_reason));
    Ok(())
}

fn pre_edit_log_failure_message(log_file: &str, detail: &str) -> String {
    let lock_path = format!("{log_file}.lock.d");
    let failure_kind = if Path::new(&lock_path).is_dir() {
        "lock"
    } else {
        "runtime"
    };
    let recovery = if failure_kind == "lock" {
        format!("if no VibeGuard hook is active, run: rmdir \"{lock_path}\"")
    } else {
        "bash scripts/hook-health.sh 24".to_string()
    };
    let project = std::env::var("VIBEGUARD_PROJECT_HASH").unwrap_or_else(|_| "unknown".to_string());
    let session = std::env::var("VIBEGUARD_SESSION_ID").unwrap_or_else(|_| "unknown".to_string());

    format!(
        "VIBEGUARD internal error [VG-INTERNAL-LOG-APPEND]: hook=pre-edit-guard tool=Edit failure_kind={failure_kind} mode=block project={project} session={session} log_path={log_file} recovery={recovery} detail=pre-edit block log append failed: {detail}"
    )
}

fn missing_file_reason(file_path: &str) -> String {
    let stem = Path::new(file_path)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .trim();

    let suggestions_enabled = std::env::var("VIBEGUARD_PRE_EDIT_SUGGEST")
        .map(|value| value != "0")
        .unwrap_or(true);

    if !suggestions_enabled {
        return format!(
            "VIBEGUARD interception: File does not exist - {file_path}. The AI may have hallucinated the file path. Please use Glob/Grep to search for the correct file path first."
        );
    }

    match missing_file_candidates(file_path, stem) {
        MissingFileCandidates::Found(candidates) => format!(
            "VIBEGUARD interception: File does not exist - {file_path}. Likely candidates (by basename stem '{stem}'):\n{}\nVerify which (if any) matches before retrying; do not re-guess the original path. Set VIBEGUARD_PRE_EDIT_SUGGEST=0 to disable candidate hints.",
            candidates
                .iter()
                .map(|candidate| format!("  {candidate}"))
                .collect::<Vec<_>>()
                .join("\n")
        ),
        MissingFileCandidates::Empty => format!(
            "VIBEGUARD interception: File does not exist - {file_path}. No similar tracked files found by basename stem. The AI may have hallucinated the path. Use Glob/Grep with a different basename before retrying."
        ),
        MissingFileCandidates::LookupFailed(detail) => format!(
            "VIBEGUARD interception: File does not exist - {file_path}. Could not search tracked files for similar paths: {detail}. The AI may have hallucinated the path. Use Glob/Grep to search manually before retrying."
        ),
    }
}

fn missing_file_candidates(file_path: &str, stem: &str) -> MissingFileCandidates {
    if stem.is_empty() {
        return MissingFileCandidates::Empty;
    }

    let Some(project_dir) = find_project_dir(file_path) else {
        return MissingFileCandidates::LookupFailed("no git project root found".to_string());
    };

    let output = match Command::new("git")
        .arg("-C")
        .arg(&project_dir)
        .arg("ls-files")
        .output()
    {
        Ok(output) => output,
        Err(exc) => {
            return MissingFileCandidates::LookupFailed(format!(
                "git ls-files could not run: {exc}"
            ));
        }
    };
    if !output.status.success() {
        let stderr_text = String::from_utf8_lossy(&output.stderr);
        let stderr = stderr_text.lines().next().map(str::trim);
        let detail = match stderr.filter(|line| !line.is_empty()) {
            Some(line) => format!("git ls-files exited with {}: {line}", output.status),
            None => format!("git ls-files exited with {}", output.status),
        };
        return MissingFileCandidates::LookupFailed(detail);
    }

    let stem_lower = stem.to_ascii_lowercase();
    let candidates = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|candidate| {
            Path::new(candidate)
                .file_stem()
                .and_then(|s| s.to_str())
                .map(|candidate_stem| candidate_stem.to_ascii_lowercase().contains(&stem_lower))
                .unwrap_or(false)
        })
        .take(3)
        .map(|candidate| project_dir.join(candidate).display().to_string())
        .collect::<Vec<_>>();
    if candidates.is_empty() {
        MissingFileCandidates::Empty
    } else {
        MissingFileCandidates::Found(candidates)
    }
}

fn decision_block_json(reason: &str) -> String {
    let escaped = serde_json::to_string(reason).unwrap_or_else(|_| "\"\"".to_string());
    format!("{{ \"decision\": \"block\", \"reason\": {escaped} }}")
}

fn hook_context_json(event_name: &str, context: &str) -> String {
    let escaped = serde_json::to_string(context).unwrap_or_else(|_| "\"\"".to_string());
    format!(
        "{{\"hookSpecificOutput\":{{\"hookEventName\":\"{event_name}\",\"additionalContext\":{escaped}}}}}"
    )
}

fn u16_advisory_limit(base_limit: usize, hard_limit: usize, warn_limit: usize) -> usize {
    if hard_limit > base_limit {
        hard_limit
    } else {
        warn_limit.min(hard_limit)
    }
}

fn u16_advisory_context(
    file_path: &str,
    line_count: usize,
    warn_limit: usize,
    hard_limit: usize,
    action: &str,
    include_search: bool,
) -> String {
    let file_name = Path::new(file_path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(file_path);
    let mut context = format!(
        "VIBEGUARD [U-16] [advisory] [this-file] OBSERVATION: {action} {file_name} with {line_count} lines exceeds the {warn_limit}-line typical range but stays under the {hard_limit}-line hard limit\nSCOPE: keep the current change localized; plan a split if this file keeps growing\nACTION: NONE — advisory only, continue without acknowledgement"
    );
    if include_search {
        context.push_str(
            "\n---\nVIBEGUARD [L1] [advisory] [this-edit] OBSERVATION: new source file detected — search for similar implementation before adding duplicates\nSCOPE: if not yet checked, consider Grep for functions/classes/structs and Glob for same-named files\nACTION: NONE — advisory only, continue without acknowledgement",
        );
    }
    context
}

pub fn post_edit_fast_check(args: &[String]) -> Result {
    if args.len() < 4 {
        return Err(
            "Usage: vibeguard-runtime post-edit-fast-check <base-limit> <session> <agent> <log-file>"
                .into(),
        );
    }

    let base_limit = args[0].parse::<usize>().unwrap_or(800);
    let session = &args[1];
    let agent = &args[2];
    let log_file = &args[3];
    let input = read_stdin()?;
    let Ok(data) = serde_json::from_str::<serde_json::Value>(&input) else {
        let mut context = "VIBEGUARD ERROR: malformed PostToolUse(Edit) hook input. The edit result could not be inspected, so this warning is reported visibly instead of silently passing.".to_string();
        if let Err(exc) = write_log_event(
            log_file,
            "post-edit-guard",
            "Edit",
            "warn",
            "Malformed hook input",
            "",
        ) {
            eprintln!("post-edit malformed input log failed: {exc}");
            let project =
                std::env::var("VIBEGUARD_PROJECT_HASH").unwrap_or_else(|_| "unknown".to_string());
            let session =
                std::env::var("VIBEGUARD_SESSION_ID").unwrap_or_else(|_| "unknown".to_string());
            context.push_str(&format!(
                "\n---\nVIBEGUARD internal error [VG-INTERNAL-LOG-APPEND]: hook=post-edit-guard tool=Edit failure_kind=runtime mode=allow project={project} session={session} log_path={log_file} recovery=bash scripts/hook-health.sh 24 detail=post-edit malformed input log append failed: {exc}"
            ));
        }
        println!("FAST_OUTPUT");
        println!("{}", hook_context_json("PostToolUse", &context));
        return Ok(());
    };

    let file_path = nested_str(&data, "tool_input.file_path").unwrap_or_default();
    let new_string = nested_str(&data, "tool_input.new_string").unwrap_or_default();
    if file_path.is_empty() || new_string.is_empty() {
        println!("SKIP");
        return Ok(());
    }
    let old_string = nested_str(&data, "tool_input.old_string").unwrap_or_default();
    let log_detail = post_edit_log_detail(&file_path, &old_string, &new_string);

    if !is_clean_rust_fast_path(&file_path, &new_string, base_limit) {
        println!("FALLBACK");
        return Ok(());
    }

    let history = match post_edit_history_signals(log_file, session, agent, &file_path) {
        Ok(history) => history,
        Err(err) => {
            eprintln!("VIBEGUARD ERROR: post-edit history read failed: {err}");
            println!("FALLBACK");
            return Ok(());
        }
    };
    if history
        .as_ref()
        .is_some_and(|signals| signals.needs_shell_w15_check())
    {
        println!("FALLBACK");
        return Ok(());
    }
    let warnings = history
        .as_ref()
        .map(|signals| post_edit_history_warnings(&file_path, signals))
        .unwrap_or_default();

    if warnings.is_empty()
        && write_log_event(log_file, "post-edit-guard", "Edit", "pass", "", &log_detail).is_ok()
    {
        println!("FAST_LOGGED");
    } else if !warnings.is_empty() {
        match build_fast_warning_output(log_file, &log_detail, &warnings, history.as_ref()) {
            Ok(output) => {
                println!("FAST_OUTPUT");
                println!("{output}");
            }
            Err(_) => {
                println!("FAST_PASS");
                println!("{file_path}");
            }
        }
    } else {
        println!("FAST_PASS");
        println!("{file_path}");
    }
    Ok(())
}

fn post_edit_log_detail(file_path: &str, old_string: &str, new_string: &str) -> String {
    let old_len = old_string.chars().count() as isize;
    let new_len = new_string.chars().count() as isize;
    format!("{file_path}||delta={}", new_len - old_len)
}

pub fn post_write_fast_check(args: &[String]) -> Result {
    if args.len() < 3 {
        return Err(
            "Usage: vibeguard-runtime post-write-fast-check <base-limit> <max-scan-files> <log-file>"
                .into(),
        );
    }

    let base_limit = args[0].parse::<usize>().unwrap_or(800);
    let max_scan_files = args[1].parse::<usize>().unwrap_or(5000);
    let log_file = &args[2];
    let input = read_stdin()?;
    let Ok(data) = serde_json::from_str::<serde_json::Value>(&input) else {
        println!("FALLBACK");
        return Ok(());
    };

    let file_path = nested_str(&data, "tool_input.file_path").unwrap_or_default();
    let content = nested_str(&data, "tool_input.content").unwrap_or_default();
    if file_path.is_empty() || content.is_empty() {
        println!("SKIP");
        return Ok(());
    }

    if !is_source_path(&file_path) {
        if write_log_event(
            log_file,
            "post-write-guard",
            "Write",
            "pass",
            "Non-source file",
            &file_path,
        )
        .is_ok()
        {
            println!("FAST_LOGGED");
        } else {
            println!("FALLBACK");
        }
        return Ok(());
    }

    if !is_clean_rust_write_fast_path(&file_path, &content, base_limit) {
        println!("FALLBACK");
        return Ok(());
    }

    let Some(project_dir) = find_project_dir(&file_path) else {
        if write_log_event(
            log_file,
            "post-write-guard",
            "Write",
            "pass",
            "No git project",
            &file_path,
        )
        .is_ok()
        {
            println!("FAST_LOGGED");
        } else {
            println!("FALLBACK");
        }
        return Ok(());
    };

    match scan_same_name_duplicate(&project_dir, &file_path, max_scan_files) {
        SameNameScan::Clean => {
            if write_log_event(
                log_file,
                "post-write-guard",
                "Write",
                "pass",
                "",
                &file_path,
            )
            .is_ok()
            {
                println!("FAST_LOGGED");
            } else {
                println!("FALLBACK");
            }
        }
        SameNameScan::Duplicate | SameNameScan::TooLarge => println!("FALLBACK"),
    }
    Ok(())
}

#[cfg(test)]
#[path = "hook_checks_tests.rs"]
mod tests;
