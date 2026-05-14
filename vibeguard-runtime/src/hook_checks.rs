use std::io;
use std::path::Path;

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

pub fn pre_write_check(args: &[String]) -> Result {
    let base_limit = args
        .first()
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(800);
    let input = read_stdin()?;
    let Ok(data) = serde_json::from_str::<serde_json::Value>(&input) else {
        println!("PASS");
        return Ok(());
    };

    let file_path = nested_str(&data, "tool_input.file_path").unwrap_or_default();
    if file_path.is_empty() {
        println!("PASS");
        return Ok(());
    }

    if is_test_infra_path(&file_path) {
        println!("W12");
        println!("{file_path}");
        return Ok(());
    }

    let content = nested_str(&data, "tool_input.content").unwrap_or_default();
    let line_count = count_lines(&content);
    if is_source_path(&file_path) && !is_test_path(&file_path) && line_count > base_limit {
        let limit = project_u16_limit(&file_path, base_limit);
        if line_count > limit {
            println!("U16_BLOCK");
            println!("{file_path}");
            println!("{line_count}");
            println!("{limit}");
            return Ok(());
        }
    }

    if Path::new(&file_path).exists() {
        println!("EXISTS");
        println!("{file_path}");
        return Ok(());
    }

    if is_allowed_new_file(&file_path) || !is_source_path(&file_path) {
        println!("ALLOW");
        println!("{file_path}");
        return Ok(());
    }

    println!("SOURCE_NEW");
    println!("{file_path}");
    Ok(())
}

pub fn pre_edit_check(args: &[String]) -> Result {
    if args.len() < 2 {
        return Err("Usage: vibeguard-runtime pre-edit-check <base-limit> <log-file>".into());
    }

    let base_limit = args[0].parse::<usize>().unwrap_or(800);
    let log_file = &args[1];
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
            &format!(
                "VIBEGUARD interception: File does not exist - {file_path}. The AI may have hallucinated the file path. Please use Glob/Grep to search for the correct file path first."
            ),
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

    if is_pre_edit_u16_source(&file_path)
        && !is_test_path(&file_path)
        && !old_string.is_empty()
        && !new_string.is_empty()
    {
        let current_lines = count_lines(&content);
        let old_lines = count_lines(&old_string);
        let new_lines = count_lines(&new_string);
        let occurrences = if replace_all {
            content.matches(&old_string).count()
        } else {
            1
        };
        let estimated = current_lines
            .saturating_sub(old_lines.saturating_mul(occurrences))
            .saturating_add(new_lines.saturating_mul(occurrences));
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
    }

    if write_log_event(log_file, "pre-edit-guard", "Edit", "pass", "", &file_path).is_ok() {
        println!("FAST_LOGGED");
    } else {
        println!("FALLBACK");
    }
    Ok(())
}

fn write_pre_edit_block(
    log_file: &str,
    log_reason: &str,
    file_path: &str,
    output_reason: &str,
) -> io::Result<()> {
    write_log_event(
        log_file,
        "pre-edit-guard",
        "Edit",
        "block",
        log_reason,
        file_path,
    )?;
    println!("FAST_OUTPUT");
    println!("{}", decision_block_json(output_reason));
    Ok(())
}

fn decision_block_json(reason: &str) -> String {
    let escaped = serde_json::to_string(reason).unwrap_or_else(|_| "\"\"".to_string());
    format!("{{ \"decision\": \"block\", \"reason\": {escaped} }}")
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
        println!("SKIP");
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

    let history = post_edit_history_signals(log_file, session, agent, &file_path);
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
        println!("SKIP");
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
            println!("FAST_PASS");
            println!("{file_path}");
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
            println!("FAST_PASS");
            println!("{file_path}");
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
                println!("FAST_PASS");
                println!("{file_path}");
            }
        }
        SameNameScan::Duplicate | SameNameScan::TooLarge => println!("FALLBACK"),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decision_block_json_escapes_reason_text() {
        let output = decision_block_json("old_string \"missing\"\nread first");
        let value: serde_json::Value =
            serde_json::from_str(&output).expect("decision output should be valid JSON");

        assert_eq!(value["decision"], "block");
        assert_eq!(value["reason"], "old_string \"missing\"\nread first");
    }

    #[test]
    fn missing_required_args_return_usage_errors_before_stdin() {
        let pre_edit = pre_edit_check(&[]).expect_err("pre-edit args should be required");
        let post_edit = post_edit_fast_check(&[]).expect_err("post-edit args should be required");
        let post_write =
            post_write_fast_check(&[]).expect_err("post-write args should be required");

        assert!(pre_edit.to_string().contains("pre-edit-check"));
        assert!(post_edit.to_string().contains("post-edit-fast-check"));
        assert!(post_write.to_string().contains("post-write-fast-check"));
    }

    #[test]
    fn post_edit_log_detail_preserves_delta_metadata() {
        assert_eq!(
            post_edit_log_detail("src/lib.rs", "old", "newer"),
            "src/lib.rs||delta=2"
        );
        assert_eq!(
            post_edit_log_detail("src/lib.rs", "abcdef", "xy"),
            "src/lib.rs||delta=-4"
        );
    }
}
