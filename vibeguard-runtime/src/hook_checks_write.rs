use regex::Regex;
use serde_json::json;
use std::path::Path;

use crate::hook_checks_common::{
    count_lines, is_source_path, is_test_path, nested_str, project_u16_limit, read_stdin,
    write_log_event,
};
use crate::hook_checks_scan::find_project_dir;
use crate::hook_checks_write_scan::{
    duplicate_definition_scan, scan_project_files, scan_project_files_with_same_name,
};

type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PostWriteConfig {
    base_limit: usize,
    warn_limit: usize,
    max_scan_files: usize,
    max_scan_defs: usize,
    max_matches: usize,
}

pub fn post_write_check(args: &[String]) -> Result {
    if args.len() < 6 {
        return Err("Usage: vibeguard-runtime post-write-check <base-limit> <warn-limit> <max-scan-files> <max-scan-defs> <max-matches> <log-file>".into());
    }

    let config = PostWriteConfig {
        base_limit: parse_usize(&args[0], 800),
        warn_limit: parse_usize(&args[1], 400),
        max_scan_files: parse_usize(&args[2], 5000),
        max_scan_defs: parse_usize(&args[3], 20),
        max_matches: parse_usize(&args[4], 5),
    };
    let log_file = &args[5];
    let input = read_stdin()?;
    let Ok(data) = serde_json::from_str::<serde_json::Value>(&input) else {
        let context = "VIBEGUARD ERROR: malformed PostToolUse(Write) hook input. The write result could not be inspected, so this warning is reported visibly instead of silently passing.";
        if let Err(exc) = write_log_event(
            log_file,
            "post-write-guard",
            "Write",
            "warn",
            "Malformed hook input",
            "",
        ) {
            eprintln!("post-write malformed input log failed: {exc}");
        }
        println!("{}", post_write_context_output(context)?);
        return Ok(());
    };

    let file_path = nested_str(&data, "tool_input.file_path").unwrap_or_default();
    let content = nested_str(&data, "tool_input.content").unwrap_or_default();
    if file_path.is_empty() || content.is_empty() {
        return Ok(());
    }

    let outcome = evaluate_post_write(&file_path, &content, config);
    match outcome {
        PostWriteOutcome::Pass { reason } => {
            write_log_event(
                log_file,
                "post-write-guard",
                "Write",
                "pass",
                reason,
                &file_path,
            )?;
        }
        PostWriteOutcome::Warn { warnings } => {
            write_log_event(
                log_file,
                "post-write-guard",
                "Write",
                "warn",
                &warnings,
                &file_path,
            )?;
            println!("{}", post_write_warning_output(&warnings)?);
        }
    }

    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
enum PostWriteOutcome {
    Pass { reason: &'static str },
    Warn { warnings: String },
}

fn evaluate_post_write(
    file_path: &str,
    content: &str,
    config: PostWriteConfig,
) -> PostWriteOutcome {
    if !is_source_path(file_path) {
        return PostWriteOutcome::Pass {
            reason: "Non-source file",
        };
    }

    let Some(project_dir) = find_project_dir(file_path) else {
        return PostWriteOutcome::Pass {
            reason: "No git project",
        };
    };

    let ext = extension(file_path);
    let mut warnings = Vec::new();
    let mut scan_incomplete = false;
    let scan_files = if ext == "go" {
        scan_project_files(&project_dir, config.max_scan_files)
    } else {
        let scan = scan_project_files_with_same_name(
            &project_dir,
            file_path,
            config.max_scan_files,
            config.max_matches,
        );
        let same_name = scan.same_name;
        scan_incomplete |= same_name.incomplete;
        if !same_name.matches.is_empty() {
            warnings.push(format!(
                "[L1] [review] [this-edit] OBSERVATION: duplicate filename found in project: {}\nSCOPE: REVIEW-ONLY - do not delete existing files or auto-merge; confirm intent before acting\nACTION: REVIEW",
                same_name.matches.join(", ")
            ));
        }
        scan.project
    };

    scan_incomplete |= scan_files.incomplete;
    if scan_files.degraded {
        warnings.push(format!(
            "[L1] [info] [this-edit] OBSERVATION: project has at least {} files, exceeding {} threshold - deep duplicate scan skipped\nSCOPE: informational only - no action required\nACTION: SKIP",
            scan_files.count, config.max_scan_files
        ));
    }

    if !scan_files.degraded {
        let duplicate_defs = duplicate_definition_scan(
            &scan_files.files,
            file_path,
            content,
            &ext,
            config.max_scan_defs,
            config.max_matches,
        );
        scan_incomplete |= duplicate_defs.incomplete;
        if !duplicate_defs.duplicates.is_empty() {
            warnings.push(format!(
                "[L1] [review] [this-edit] OBSERVATION: duplicate definition(s) found in project: {}\nFIX: Reuse the existing definition instead of creating a new one\nDO NOT: Delete existing definitions or merge code without confirming intent",
                duplicate_defs.duplicates.join(" ")
            ));
        }
    }

    if scan_incomplete {
        warnings.push(
            "[L1] [info] [this-edit] OBSERVATION: post-write project scan was incomplete because one or more paths could not be read\nSCOPE: informational only - review manually if this result looks suspicious\nACTION: REVIEW"
                .to_string(),
        );
    }

    if let Some(stub_warning) = stub_warning(file_path, content) {
        warnings.push(stub_warning);
    }

    if let Some(u16_warning) = u16_warning(file_path, content, config.base_limit, config.warn_limit)
    {
        warnings.push(u16_warning);
    }

    if warnings.is_empty() {
        PostWriteOutcome::Pass { reason: "" }
    } else {
        PostWriteOutcome::Warn {
            warnings: warnings.join("\n---\n"),
        }
    }
}

fn stub_warning(file_path: &str, content: &str) -> Option<String> {
    let (patterns, lang_desc) = match extension(file_path).as_str() {
        "rs" => {
            if !(content.contains("todo!(")
                || content.contains("unimplemented!(")
                || content.contains("panic!(\"not implemented"))
            {
                return None;
            }
            (
                &[
                    r"^\s*todo!\(",
                    r"^\s*unimplemented!\(",
                    r#"^\s*panic!\("not implemented"#,
                ][..],
                "todo!/unimplemented!",
            )
        }
        "ts" | "tsx" | "js" | "jsx" => {
            if !(content.contains("not implemented")
                || content.contains("TODO")
                || content.contains("FIXME")
                || content.contains("stub"))
            {
                return None;
            }
            (
                &[
                    r"^\s*throw new Error\(.*(not implemented|TODO|FIXME)",
                    r"^\s*// TODO",
                    r"^\s*// FIXME",
                    r"^\s*return null.*// stub",
                ][..],
                "throw not implemented / TODO",
            )
        }
        "py" => {
            if !(content.contains("pass")
                || content.contains("NotImplementedError")
                || content.contains("TODO")
                || content.contains("FIXME"))
            {
                return None;
            }
            (
                &[
                    r"^\s*pass\s*$",
                    r"^\s*pass\s*#",
                    r"^\s*raise NotImplementedError",
                    r"^\s*# TODO",
                    r"^\s*# FIXME",
                ][..],
                "pass/NotImplementedError/TODO",
            )
        }
        "go" => {
            if !(content.contains("panic(\"not implemented")
                || content.contains("TODO")
                || content.contains("FIXME"))
            {
                return None;
            }
            (
                &[
                    r#"^\s*panic\("not implemented"#,
                    r"^\s*// TODO",
                    r"^\s*// FIXME",
                ][..],
                "panic not implemented / TODO",
            )
        }
        _ => return None,
    };

    let mut stub_count = 0usize;
    for pattern in patterns {
        let Ok(regex) = Regex::new(pattern) else {
            continue;
        };
        stub_count += content.lines().filter(|line| regex.is_match(line)).count();
    }

    if stub_count == 0 {
        return None;
    }
    Some(format!(
        "[STUB] [review] [this-edit] OBSERVATION: {stub_count} stub placeholder(s) found in new file ({lang_desc})\nFIX: Replace with real implementation in this task, or add a DEFER comment explaining why\nDO NOT: Add DEFER markers to stubs in other files"
    ))
}

fn u16_warning(
    file_path: &str,
    content: &str,
    base_limit: usize,
    warn_limit: usize,
) -> Option<String> {
    if !matches!(
        extension(file_path).as_str(),
        "rs" | "ts" | "tsx" | "js" | "jsx" | "py" | "go"
    ) || is_test_path(file_path)
    {
        return None;
    }

    let total = count_lines(content);
    if total <= warn_limit {
        return None;
    }

    let limit = project_u16_limit(file_path, base_limit);
    if total > limit {
        return Some(format!(
            "[U-16] [review] [this-file] OBSERVATION: file has {total} lines, exceeding {limit}-line limit\nFIX: Split into focused submodules by responsibility; plan as a separate task\nDO NOT: Start splitting now - finish the current task first, then refactor"
        ));
    }
    if limit <= base_limit && total > warn_limit {
        return Some(format!(
            "[U-16] [advisory] [this-file] OBSERVATION: file has {total} lines, exceeding the {warn_limit}-line typical range while staying under the {limit}-line hard limit\nFIX: Keep the current change localized; plan a split if this file keeps growing\nDO NOT: Start splitting now - finish the current task first, then refactor"
        ));
    }
    None
}

fn post_write_warning_output(warnings: &str) -> Result<String> {
    post_write_context_output(&format!("VIBEGUARD duplicate detection:{warnings}"))
}

fn post_write_context_output(context: &str) -> Result<String> {
    Ok(serde_json::to_string(&json!({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": context,
        }
    }))?)
}

fn parse_usize(value: &str, fallback: usize) -> usize {
    value.parse::<usize>().unwrap_or(fallback)
}

fn extension(file_path: &str) -> String {
    Path::new(file_path)
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_string()
}

#[cfg(test)]
#[path = "hook_checks_write_tests.rs"]
mod tests;
