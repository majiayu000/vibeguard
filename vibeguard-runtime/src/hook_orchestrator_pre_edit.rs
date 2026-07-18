use serde_json::{Value, json};
use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

use crate::event_schema::{decision, status};
use crate::hook_checks_common::{
    count_lines, is_pre_edit_u16_source, is_test_infra_path, is_test_path, nested_str,
    project_u16_limit, read_lossy_file,
};
use crate::hook_checks_scan::find_project_dir;
use crate::hook_orchestrator::{
    HookKind, Result, append_hook_event, elapsed_ms, print_policy_decision_kv,
};
use crate::hook_orchestrator_context::RuntimeContext;

#[derive(Debug, PartialEq, Eq)]
enum MissingFileCandidates {
    Found(Vec<String>),
    Empty,
    LookupFailed(String),
}

pub(crate) fn run(ctx: &RuntimeContext, input: &str, start: Instant) -> Result {
    let data = match serde_json::from_str::<Value>(input) {
        Ok(data) => data,
        Err(_) => {
            block_with_log(
                ctx,
                start,
                "Malformed hook input",
                "",
                MALFORMED_PRE_EDIT_REASON,
            )?;
            return Ok(());
        }
    };

    let file_path = nested_str(&data, "tool_input.file_path").unwrap_or_default();
    if file_path.is_empty() {
        return Ok(());
    }

    if is_test_infra_path(&file_path) {
        block_with_log(
            ctx,
            start,
            "Test Infrastructure File Protection (W-12)",
            &file_path,
            &format!(
                "VIBEGUARD W-12 interception: Modification of test infrastructure files - {file_path} is prohibited. AI agents must not modify test framework configuration files such as conftest.py/jest.config/pytest.ini/.coveragerc. Such modifications may cause tests to be bypassed instead of actually fixing code problems. Please fix the code under test rather than manipulating the test framework."
            ),
        )?;
        return Ok(());
    }

    if !Path::new(&file_path).is_file() {
        block_with_log(
            ctx,
            start,
            "File does not exist",
            &file_path,
            &missing_file_reason(&file_path),
        )?;
        return Ok(());
    }

    let content = match read_lossy_file(&file_path) {
        Ok(content) => content,
        Err(err) => {
            block_with_log(
                ctx,
                start,
                "File read failed",
                &file_path,
                &format!(
                    "VIBEGUARD interception: File could not be read - {file_path}: {err}. The edit request could not be validated, so it was blocked instead of being treated as safe."
                ),
            )?;
            return Ok(());
        }
    };

    let old_string = nested_str(&data, "tool_input.old_string").unwrap_or_default();
    let new_string = nested_str(&data, "tool_input.new_string").unwrap_or_default();
    if !old_string.is_empty() && !content.contains(&old_string) {
        block_with_log(
            ctx,
            start,
            "old_string does not exist",
            &file_path,
            "VIBEGUARD interception: old_string does not exist in the file - the AI may have hallucinated the file content. Please use the Read tool to read the file first to confirm that the content to be replaced actually exists.",
        )?;
        return Ok(());
    }

    if let Some(context_or_reason) =
        pre_edit_u16_result(&data, &file_path, &content, &old_string, &new_string)
    {
        match context_or_reason {
            PreEditU16Result::Block { log_reason, output } => {
                block_with_log(ctx, start, &log_reason, &file_path, &output)?;
            }
            PreEditU16Result::Advisory {
                log_reason,
                context,
            } => {
                if let Err(err) = append_hook_event(
                    ctx,
                    HookKind::PreEdit,
                    decision::WARN,
                    status::WARN,
                    &log_reason,
                    &file_path,
                    elapsed_ms(start),
                ) {
                    print_internal_warning(ctx, Some(&context), &err.to_string())?;
                } else {
                    print_hook_context("PreToolUse", &context)?;
                }
            }
        }
        return Ok(());
    }

    if let Err(err) = append_hook_event(
        ctx,
        HookKind::PreEdit,
        decision::PASS,
        status::PASS,
        "",
        &file_path,
        elapsed_ms(start),
    ) {
        print_internal_warning(ctx, None, &err.to_string())?;
    }

    Ok(())
}

enum PreEditU16Result {
    Block { log_reason: String, output: String },
    Advisory { log_reason: String, context: String },
}

fn pre_edit_u16_result(
    data: &Value,
    file_path: &str,
    content: &str,
    old_string: &str,
    new_string: &str,
) -> Option<PreEditU16Result> {
    if !is_pre_edit_u16_source(file_path) || is_test_path(file_path) {
        return None;
    }

    let current_lines = count_lines(content);
    let estimated = if let Some(delta) = data
        .get("tool_input")
        .and_then(|value| value.get("vibeguard_line_delta"))
        .and_then(Value::as_i64)
    {
        if delta >= 0 {
            Some(current_lines.saturating_add(delta as usize))
        } else {
            let decrease = usize::try_from(delta.unsigned_abs()).unwrap_or(usize::MAX);
            Some(current_lines.saturating_sub(decrease))
        }
    } else if !old_string.is_empty() && !new_string.is_empty() {
        let old_lines = count_lines(old_string);
        let new_lines = count_lines(new_string);
        let replace_all = data
            .get("tool_input")
            .and_then(|value| value.get("replace_all"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let occurrences = if replace_all {
            content.matches(old_string).count()
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
    }?;

    let base_limit =
        crate::runtime_config::runtime_config_int_value("VG_U16_LIMIT", "u16.limit", "800")
            as usize;
    let warn_limit = crate::runtime_config::runtime_config_int_value(
        "VG_U16_WARN_LIMIT",
        "u16.warn_limit",
        "400",
    ) as usize;
    let limit = project_u16_limit(file_path, base_limit);
    if estimated > limit {
        return Some(PreEditU16Result::Block {
            log_reason: format!("U-16 file size: {estimated} > {limit}"),
            output: format!(
                "VIBEGUARD [U-16] block: this edit would bring {} to ~{estimated} lines (limit: {limit}). Split the file into focused submodules before adding more code. Do NOT proceed with this edit.",
                file_name(file_path)
            ),
        });
    }

    let advisory_limit = u16_advisory_limit(base_limit, limit, warn_limit);
    if advisory_limit < limit && estimated > advisory_limit {
        return Some(PreEditU16Result::Advisory {
            log_reason: format!("U-16 file size advisory: {estimated} > {advisory_limit}"),
            context: u16_advisory_context(file_path, estimated, advisory_limit, limit),
        });
    }

    None
}

fn block_with_log(
    ctx: &RuntimeContext,
    start: Instant,
    log_reason: &str,
    file_path: &str,
    output_reason: &str,
) -> Result {
    let mut visible_reason = output_reason.to_string();
    if let Err(err) = append_hook_event(
        ctx,
        HookKind::PreEdit,
        decision::BLOCK,
        status::BLOCK,
        log_reason,
        file_path,
        elapsed_ms(start),
    ) {
        eprintln!("VIBEGUARD ERROR: pre-edit block log append failed: {err}");
        visible_reason.push_str("\n\n");
        visible_reason.push_str(&log_failure_message(ctx, "block", &err.to_string()));
    }
    print_policy_decision_kv("block", &visible_reason);
    Ok(())
}

fn print_internal_warning(
    ctx: &RuntimeContext,
    preceding_context: Option<&str>,
    detail: &str,
) -> Result {
    let message = log_failure_message(ctx, "allow", detail);
    let context = match preceding_context {
        Some(context) if !context.is_empty() => format!("{context}\n\n{message}"),
        _ => message,
    };
    print_hook_context("PreToolUse", &context)
}

fn log_failure_message(ctx: &RuntimeContext, mode: &str, detail: &str) -> String {
    let log_path = failure_log_path(ctx);
    let lock_path = PathBuf::from(format!("{}.lock.d", log_path.display()));
    let failure_kind = if lock_path.is_dir() {
        "lock"
    } else {
        "runtime"
    };
    let recovery = if failure_kind == "lock" {
        format!(
            "if no VibeGuard hook is active, run: rmdir \"{}\"",
            lock_path.display()
        )
    } else {
        "bash scripts/hook-health.sh 24".to_string()
    };

    format!(
        "VIBEGUARD internal error [VG-INTERNAL-LOG-APPEND]: hook=pre-edit-guard tool=Edit failure_kind={failure_kind} mode={mode} project={} session={} log_path={} recovery={recovery} detail=pre-edit log append failed: {detail}",
        ctx.project_hash,
        ctx.session_id,
        log_path.display()
    )
}

fn failure_log_path(ctx: &RuntimeContext) -> PathBuf {
    let project_lock = PathBuf::from(format!("{}.lock.d", ctx.log_file.display()));
    if project_lock.is_dir() {
        return ctx.log_file.clone();
    }
    let global_log = ctx.log_root.join("events.jsonl");
    let global_lock = PathBuf::from(format!("{}.lock.d", global_log.display()));
    if global_lock.is_dir() {
        return global_log;
    }
    ctx.log_file.clone()
}

fn print_hook_context(event_name: &str, context: &str) -> Result {
    println!(
        "{}",
        serde_json::to_string(&json!({
            "hookSpecificOutput": {
                "hookEventName": event_name,
                "additionalContext": context,
            }
        }))?
    );
    Ok(())
}

fn missing_file_reason(file_path: &str) -> String {
    let stem = Path::new(file_path)
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .trim();

    let suggestions_enabled = env::var("VIBEGUARD_PRE_EDIT_SUGGEST")
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
        Err(err) => {
            return MissingFileCandidates::LookupFailed(format!(
                "git ls-files could not run: {err}"
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
                .and_then(|value| value.to_str())
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
) -> String {
    format!(
        "VIBEGUARD [U-16] [advisory] [this-file] OBSERVATION: this edit would leave {} with {line_count} lines exceeds the {warn_limit}-line typical range but stays under the {hard_limit}-line hard limit\nSCOPE: keep the current change localized; plan a split if this file keeps growing\nACTION: NONE - advisory only, continue without acknowledgement",
        file_name(file_path)
    )
}

fn file_name(path: &str) -> &str {
    Path::new(path)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(path)
}

const MALFORMED_PRE_EDIT_REASON: &str = "VIBEGUARD interception: malformed PreToolUse(Edit) hook input. The edit request could not be validated, so it was blocked instead of being treated as a safe skip.";

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn unique_temp_dir(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time after unix epoch")
            .as_nanos();
        env::temp_dir().join(format!(
            "vibeguard-pre-edit-{label}-{}-{nanos}",
            std::process::id()
        ))
    }

    fn git(repo: &Path, args: &[&str]) {
        let output = Command::new("git")
            .current_dir(repo)
            .args(args)
            .output()
            .expect("git command runs");
        assert!(
            output.status.success(),
            "git {args:?}\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn line_repeated(count: usize) -> String {
        std::iter::repeat_n("fn value() {}", count)
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn missing_file_candidates_reports_tracked_stem_matches() {
        let root = unique_temp_dir("candidates");
        let repo = root.join("repo");
        fs::create_dir_all(repo.join("src")).expect("create src");
        git(&repo, &["init"]);
        let candidate = repo.join("src/hook_orchestrator_pre_edit.rs");
        fs::write(&candidate, "fn existing() {}\n").expect("write candidate");
        git(&repo, &["add", "src/hook_orchestrator_pre_edit.rs"]);

        let missing = repo.join("src/pre_edit_runtime.rs");
        let candidates = missing_file_candidates(&missing.to_string_lossy(), "pre_edit");

        match candidates {
            MissingFileCandidates::Found(paths) => {
                assert_eq!(paths, vec![candidate.display().to_string()]);
            }
            other => panic!("expected tracked candidate, got {other:?}"),
        }

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn missing_file_candidates_returns_empty_for_blank_stem() {
        assert_eq!(
            missing_file_candidates("src/lib.rs", ""),
            MissingFileCandidates::Empty
        );
    }

    #[test]
    fn pre_edit_u16_result_blocks_delta_over_hard_limit() {
        let root = unique_temp_dir("u16-block");
        let file_path = root.join("src/lib.rs");
        let data = json!({
            "tool_input": {
                "vibeguard_line_delta": 1
            }
        });
        let content = line_repeated(800);

        let result = pre_edit_u16_result(&data, &file_path.to_string_lossy(), &content, "", "");

        match result {
            Some(PreEditU16Result::Block { log_reason, output }) => {
                assert_eq!(log_reason, "U-16 file size: 801 > 800");
                assert!(output.contains("lib.rs"), "{output}");
                assert!(output.contains("Do NOT proceed"), "{output}");
            }
            _ => panic!("expected U-16 block"),
        }

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn u16_advisory_limit_respects_project_specific_hard_limit() {
        assert_eq!(u16_advisory_limit(800, 1200, 400), 1200);
        assert_eq!(u16_advisory_limit(800, 800, 400), 400);
        assert_eq!(u16_advisory_limit(800, 300, 400), 300);
    }
}
