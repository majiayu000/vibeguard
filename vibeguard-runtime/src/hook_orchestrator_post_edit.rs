use regex::Regex;
use serde_json::{Value, json};
use std::fs;
use std::path::Path;
use std::time::Instant;

use crate::event_schema::{decision, status};
use crate::hook_checks_common::{
    count_lines, is_pre_edit_u16_source, is_test_path, nested_str, project_u16_limit,
    read_lossy_file,
};
use crate::hook_orchestrator::{HookKind, Result, append_hook_event, elapsed_ms};
use crate::hook_orchestrator_context::RuntimeContext;
use crate::hook_orchestrator_post_edit_history::{
    count_prior_warn_events, detect_history_warnings,
};
use crate::runtime_config::runtime_config_int_value;

pub(crate) fn run(ctx: &RuntimeContext, input: &str, start: Instant) -> Result {
    let data = match serde_json::from_str::<Value>(input) {
        Ok(data) => data,
        Err(_) => {
            let context = "VIBEGUARD ERROR: malformed PostToolUse(Edit) hook input. The edit result could not be inspected, so this warning is reported visibly instead of silently passing.";
            let _ = append_hook_event(
                ctx,
                HookKind::PostEdit,
                decision::WARN,
                status::WARN,
                "Malformed hook input",
                "",
                elapsed_ms(start),
            );
            print_context(context)?;
            return Ok(());
        }
    };

    let file_path = nested_str(&data, "tool_input.file_path").unwrap_or_default();
    let new_string = nested_str(&data, "tool_input.new_string").unwrap_or_default();
    if file_path.is_empty() || new_string.is_empty() {
        return Ok(());
    }
    let old_string = nested_str(&data, "tool_input.old_string").unwrap_or_default();
    let detail = post_edit_log_detail(&file_path, &old_string, &new_string);
    let mut warnings = Vec::new();

    detect_stateless_warnings(&file_path, &new_string, &mut warnings);
    detect_history_warnings(
        ctx,
        start,
        &file_path,
        &detail,
        &old_string,
        &new_string,
        &mut warnings,
    );

    if warnings.is_empty() {
        if let Err(err) = append_hook_event(
            ctx,
            HookKind::PostEdit,
            decision::PASS,
            status::PASS,
            "",
            &detail,
            elapsed_ms(start),
        ) {
            print_context(&internal_context(ctx, "allow", &err.to_string()))?;
        }
        return Ok(());
    }

    let mut decision_value = decision::WARN;
    let mut reason = warnings.join("\n---\n");
    let prior_warn_count = count_prior_warn_events(ctx, &file_path);
    if prior_warn_count >= 3 {
        decision_value = decision::ESCALATE;
        reason = format!(
            "[ESCALATE] [review] [this-file] OBSERVATION: this file has triggered {prior_warn_count} warnings — user intervention recommended\nFIX: Stop and review the warnings below before continuing\nDO NOT: Continue editing this file without reviewing all warnings\n---\n{reason}"
        );
    }

    if let Err(err) = append_hook_event(
        ctx,
        HookKind::PostEdit,
        decision_value,
        decision_value,
        &reason,
        &detail,
        elapsed_ms(start),
    ) {
        print_context(&internal_context(ctx, "allow", &err.to_string()))?;
        return Ok(());
    }

    let prefix = if decision_value == decision::ESCALATE {
        "VIBEGUARD upgrade warning"
    } else {
        "VIBEGUARD quality warning"
    };
    print_context(&format!("{prefix}：{reason}"))?;
    Ok(())
}

fn detect_stateless_warnings(file_path: &str, new_string: &str, warnings: &mut Vec<String>) {
    detect_rust(file_path, new_string, warnings);
    detect_ts_console(file_path, new_string, warnings);
    detect_python_print(file_path, new_string, warnings);
    detect_hardcoded_db_path(file_path, new_string, warnings);
    detect_go(file_path, new_string, warnings);
    detect_stubs(file_path, new_string, warnings);
    detect_large_edit(new_string, warnings);
    detect_u16_size(file_path, warnings);
}

fn detect_rust(file_path: &str, new_string: &str, warnings: &mut Vec<String>) {
    if !file_path.ends_with(".rs") || is_test_path(file_path) {
        return;
    }
    let filtered = filter_suppressed(new_string, "RS-03");
    let unsafe_count = count_regex(&filtered, r"\.(unwrap|expect)\(");
    let safe_count = count_regex(
        &filtered,
        r"\.(unwrap_or|unwrap_or_else|unwrap_or_default)\(",
    );
    let real_count = unsafe_count.saturating_sub(safe_count);
    if real_count > 0 {
        warnings.push(format!(
            "[RS-03] [review] [this-edit] OBSERVATION: {real_count} new unwrap()/expect() call(s) added\nSCOPE: this-edit only — do not propagate changes beyond this edit, add error types, or change signatures\nACTION: REVIEW"
        ));
    }

    let silent_count = count_regex(
        &filter_suppressed(new_string, "RS-10"),
        r"(?m)^\s*let\s+_\s*=",
    );
    if silent_count > 0 {
        warnings.push(format!(
            "[RS-10] [review] [this-edit] OBSERVATION: {silent_count} new let _ = silent discard(s) added\nSCOPE: this-edit only — do not refactor calling code or add new error types\nACTION: REVIEW"
        ));
    }
}

fn detect_ts_console(file_path: &str, new_string: &str, warnings: &mut Vec<String>) {
    if !matches!(extension(file_path).as_str(), "ts" | "tsx" | "js" | "jsx") {
        return;
    }
    let lower = file_path.replace('\\', "/").to_ascii_lowercase();
    if is_test_path(file_path)
        || lower.contains("/debug.")
        || lower.contains("/debug/")
        || lower.contains("logger")
        || lower.contains("logging")
        || is_cli_project(file_path)
        || file_contains(
            file_path,
            &["StdioServerTransport", "new Server(", "McpServer"],
        )
    {
        return;
    }
    let console_count = count_regex(
        &filter_suppressed(new_string, "DEBUG"),
        r"\bconsole\.(log|warn|error)\(",
    );
    if console_count == 0 {
        return;
    }
    let file_console_total = read_lossy_file(file_path)
        .ok()
        .map(|text| count_regex(&text, r"\bconsole\.(log|warn|error)\("))
        .unwrap_or(0);
    if file_console_total >= 10 {
        warnings.push(format!(
            "[DEBUG] [review] [this-file] OBSERVATION: file has {file_console_total} console residuals and new ones are being added\nFIX: Remove this console.log/warn/error call; keep only if this is intentional debug output\nDO NOT: Create logger modules, modify other files, or fix console usage outside this file"
        ));
    } else {
        warnings.push(format!(
            "[DEBUG] [review] [this-edit] OBSERVATION: {console_count} new console.log/warn/error call(s) added\nFIX: Remove this console.log/warn/error call; keep only if this is a CLI project (check bin field in package.json)\nDO NOT: Create new logger modules, modify other files, or fix console usage outside this edit"
        ));
    }
}

fn detect_python_print(file_path: &str, new_string: &str, warnings: &mut Vec<String>) {
    if !file_path.ends_with(".py") || is_test_path(file_path) {
        return;
    }
    let print_count = count_regex(&filter_suppressed(new_string, "DEBUG"), r"(?m)^\s*print\(");
    if print_count > 0 {
        warnings.push(format!(
            "[DEBUG] [review] [this-edit] OBSERVATION: {print_count} new print() statement(s) added\nFIX: Remove this print() call, or replace with logging.getLogger(__name__).debug() for permanent logging\nDO NOT: Modify logging configuration or other files"
        ));
    }
}

fn detect_hardcoded_db_path(file_path: &str, new_string: &str, warnings: &mut Vec<String>) {
    if is_test_path(file_path)
        || !(new_string.contains(".db\"") || new_string.contains(".sqlite\""))
    {
        return;
    }
    if count_regex(
        &filter_suppressed(new_string, "U-11"),
        r#""[^"]*\.(db|sqlite)""#,
    ) > 0
    {
        warnings.push("[U-11] [review] [this-line] OBSERVATION: hardcoded database path (.db/.sqlite) detected\nFIX: Extract to a shared default_db_path() function in core layer; use env var APP_DB_PATH for override\nDO NOT: Refactor path functions, move code to another file, or change other hardcoded paths".to_string());
    }
}

fn detect_go(file_path: &str, new_string: &str, warnings: &mut Vec<String>) {
    if !file_path.ends_with(".go")
        || file_path.ends_with("_test.go")
        || file_path.contains("/vendor/")
    {
        return;
    }
    let filtered = filter_suppressed(new_string, "GO-01");
    let discard_re = match Regex::new(r"^\s*_\s*(,\s*_)?\s*[:=]+") {
        Ok(regex) => regex,
        Err(err) => {
            warnings.push(format!(
                "[GO-01] [review] [this-edit] OBSERVATION: VibeGuard internal regex initialization failed: {err}\nFIX: Report this VibeGuard hook failure\nDO NOT: Continue assuming Go discard detection ran"
            ));
            return;
        }
    };
    let ignore_re = match Regex::new(r"(for\s+.*range|,\s*(ok|found|exists)\s*:?=)") {
        Ok(regex) => regex,
        Err(err) => {
            warnings.push(format!(
                "[GO-01] [review] [this-edit] OBSERVATION: VibeGuard internal regex initialization failed: {err}\nFIX: Report this VibeGuard hook failure\nDO NOT: Continue assuming Go discard detection ran"
            ));
            return;
        }
    };
    let err_discard = filtered
        .lines()
        .filter(|line| discard_re.is_match(line) && !ignore_re.is_match(line))
        .count();
    if err_discard > 0 {
        warnings.push(format!(
            "[GO-01] [auto-fix] [this-line] OBSERVATION: {err_discard} new error discard(s) (\"_ = ...\") added\nFIX: Replace _ = fn() with err := fn(); if err != nil {{ return fmt.Errorf(\"context: %w\", err) }}\nDO NOT: Modify function signatures or upstream callers"
        ));
    }
    if defer_inside_loop(&filter_suppressed(new_string, "GO-08")) {
        warnings.push("[GO-08] [review] [this-edit] OBSERVATION: defer inside a loop detected, may cause resource leak\nFIX: Extract the loop body containing defer into a separate function\nDO NOT: Extract to a separate file or refactor loop logic beyond the current edit".to_string());
    }
}

fn detect_stubs(file_path: &str, new_string: &str, warnings: &mut Vec<String>) {
    let (patterns, lang_desc) = match extension(file_path).as_str() {
        "rs" if has_any(
            new_string,
            &["todo!(", "unimplemented!(", "panic!(\"not implemented"],
        ) =>
        {
            (
                vec![r#"^\s*(todo!\(|unimplemented!\(|panic!\("not implemented)"#],
                "todo!/unimplemented!",
            )
        }
        "ts" | "tsx" | "js" | "jsx"
            if has_any(new_string, &["not implemented", "TODO", "FIXME", "stub"]) =>
        {
            (
                vec![
                    r#"^\s*(throw new Error\(.*(not implemented|TODO|FIXME)|// TODO|// FIXME|return null.*// stub)"#,
                ],
                "throw not implemented / TODO",
            )
        }
        "py" if has_any(
            new_string,
            &["pass", "NotImplementedError", "TODO", "FIXME"],
        ) =>
        {
            (
                vec![r"^\s*(pass\s*$|pass\s*#|raise NotImplementedError|# TODO|# FIXME)"],
                "pass/NotImplementedError/TODO",
            )
        }
        "go" if has_any(new_string, &["panic(\"not implemented", "TODO", "FIXME"]) => (
            vec![r#"^\s*(panic\("not implemented|// TODO|// FIXME)"#],
            "panic not implemented / TODO",
        ),
        _ => return,
    };
    let filtered = filter_suppressed(new_string, "STUB");
    let stub_count = patterns
        .iter()
        .map(|pattern| count_regex(&filtered, pattern))
        .sum::<usize>();
    if stub_count > 0 {
        warnings.push(format!(
            "[STUB] [review] [this-edit] OBSERVATION: {stub_count} stub placeholder(s) added ({lang_desc})\nFIX: Replace with real implementation in this task, or add a DEFER comment explaining why\nDO NOT: Add DEFER markers to stubs in other files"
        ));
    }
}

fn detect_large_edit(new_string: &str, warnings: &mut Vec<String>) {
    let diff_lines = count_lines(new_string);
    if diff_lines > 200 {
        warnings.push(format!(
            "[LARGE-EDIT] [info] [this-edit] OBSERVATION: single edit contains {diff_lines} lines, exceeding 200-line threshold\nFIX: Verify the edit content is correct and intentional\nDO NOT: Take any action — this is informational only"
        ));
    }
}

fn detect_u16_size(file_path: &str, warnings: &mut Vec<String>) {
    if !is_pre_edit_u16_source(file_path)
        || is_test_path(file_path)
        || !Path::new(file_path).is_file()
    {
        return;
    }
    let Ok(content) = read_lossy_file(file_path) else {
        return;
    };
    let total = count_lines(&content);
    let base_limit = runtime_config_int_value("VG_U16_LIMIT", "u16.limit", "800") as usize;
    let warn_limit =
        runtime_config_int_value("VG_U16_WARN_LIMIT", "u16.warn_limit", "400") as usize;
    if total <= warn_limit {
        return;
    }
    let limit = project_u16_limit(file_path, base_limit);
    if total > limit {
        warnings.push(format!(
            "[U-16] [review] [this-file] OBSERVATION: file has {total} lines, exceeding {limit}-line limit\nFIX: Split into focused submodules by responsibility; plan as a separate task\nDO NOT: Start splitting now — finish the current task first, then refactor"
        ));
    } else if limit <= base_limit {
        warnings.push(format!(
            "[U-16] [advisory] [this-file] OBSERVATION: file has {total} lines, exceeding the {warn_limit}-line typical range while staying under the {limit}-line hard limit\nFIX: Keep the current change localized; plan a split if this file keeps growing\nDO NOT: Start splitting now — finish the current task first, then refactor"
        ));
    }
}

fn filter_suppressed(content: &str, rule: &str) -> String {
    let mut out = Vec::new();
    let mut suppress_next = false;
    let mut in_template = false;
    let mut in_triple_dq = false;
    let mut in_triple_sq = false;
    for line in content.lines() {
        let start_in_ml = in_template || in_triple_dq || in_triple_sq;
        if line.matches('`').count() % 2 == 1 {
            in_template = !in_template;
        }
        if line.matches("\"\"\"").count() % 2 == 1 {
            in_triple_dq = !in_triple_dq;
        }
        if line.matches("'''").count() % 2 == 1 {
            in_triple_sq = !in_triple_sq;
        }
        if suppress_next {
            suppress_next = false;
            continue;
        }
        if !start_in_ml && is_suppress_directive(line, rule) {
            suppress_next = true;
            continue;
        }
        out.push(line);
    }
    out.join("\n")
}

fn is_suppress_directive(line: &str, rule: &str) -> bool {
    let trimmed = line.trim_start();
    let Some(rest) = trimmed
        .strip_prefix("//")
        .or_else(|| trimmed.strip_prefix('#'))
    else {
        return false;
    };
    let rest = rest.trim_start();
    let Some(after) = rest.strip_prefix("vibeguard-disable-next-line") else {
        return false;
    };
    let after = after.trim_start();
    after == rule
        || after.starts_with(&format!("{rule} "))
        || after.starts_with(&format!("{rule}--"))
}

fn count_regex(content: &str, pattern: &str) -> usize {
    Regex::new(pattern)
        .map(|regex| regex.find_iter(content).count())
        .unwrap_or(0)
}

fn defer_inside_loop(content: &str) -> bool {
    let mut in_loop = false;
    for line in content.lines() {
        let trimmed = line.trim_start();
        if trimmed.starts_with("for ") {
            in_loop = true;
        }
        if in_loop && trimmed.starts_with("defer ") {
            return true;
        }
        if trimmed.starts_with('}') {
            in_loop = false;
        }
    }
    false
}

fn is_cli_project(file_path: &str) -> bool {
    let mut dir = Path::new(file_path).parent();
    while let Some(path) = dir {
        if let Ok(package) = fs::read_to_string(path.join("package.json")) {
            if package.contains("\"bin\"") || package.contains("cli") {
                return true;
            }
        }
        if path.join("src/cli.ts").exists()
            || path.join("src/cli.js").exists()
            || path.join("cli.ts").exists()
            || path.join("cli.js").exists()
        {
            return true;
        }
        dir = path.parent();
    }
    false
}

fn file_contains(file_path: &str, needles: &[&str]) -> bool {
    read_lossy_file(file_path)
        .map(|content| needles.iter().any(|needle| content.contains(needle)))
        .unwrap_or(false)
}

fn has_any(content: &str, needles: &[&str]) -> bool {
    needles.iter().any(|needle| content.contains(needle))
}

fn post_edit_log_detail(file_path: &str, old_string: &str, new_string: &str) -> String {
    let old_len = old_string.chars().count() as isize;
    let new_len = new_string.chars().count() as isize;
    format!("{file_path}||delta={}", new_len - old_len)
}

fn print_context(context: &str) -> Result {
    println!(
        "{}",
        serde_json::to_string(&json!({
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": context,
            }
        }))?
    );
    Ok(())
}

fn internal_context(ctx: &RuntimeContext, mode: &str, detail: &str) -> String {
    format!(
        "VIBEGUARD internal error [VG-INTERNAL-LOG-APPEND]: hook=post-edit-guard tool=Edit failure_kind=runtime mode={mode} project={} session={} log_path={} recovery=bash scripts/hook-health.sh 24 detail=post-edit log append failed: {detail}",
        ctx.project_hash,
        ctx.session_id,
        ctx.log_file.display()
    )
}

fn extension(file_path: &str) -> String {
    Path::new(file_path)
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_string()
}
