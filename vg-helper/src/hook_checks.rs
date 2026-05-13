use serde_json::Value;
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use crate::event_schema::{field, hook, tool};
use crate::time_utils::{format_unix_secs_utc, now_unix_secs, parse_iso_ts};

type Result = std::result::Result<(), Box<dyn std::error::Error>>;
const POST_EDIT_HISTORY_LINES: usize = 500;

pub fn pre_write_check(args: &[String]) -> Result {
    let base_limit = args
        .first()
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(800);
    let input = read_stdin()?;
    let Ok(data) = serde_json::from_str::<Value>(&input) else {
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
        return Err("Usage: vg-helper pre-edit-check <base-limit> <log-file>".into());
    }

    let base_limit = args[0].parse::<usize>().unwrap_or(800);
    let log_file = &args[1];
    let input = read_stdin()?;
    let Ok(data) = serde_json::from_str::<Value>(&input) else {
        println!("SKIP");
        return Ok(());
    };

    let file_path = nested_str(&data, "tool_input.file_path").unwrap_or_default();
    let old_string = nested_str(&data, "tool_input.old_string").unwrap_or_default();
    let new_string = nested_str(&data, "tool_input.new_string").unwrap_or_default();
    let replace_all = data
        .get("tool_input")
        .and_then(|v| v.get("replace_all"))
        .and_then(Value::as_bool)
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
            "Usage: vg-helper post-edit-fast-check <base-limit> <session> <agent> <log-file>"
                .into(),
        );
    }

    let base_limit = args[0].parse::<usize>().unwrap_or(800);
    let session = &args[1];
    let agent = &args[2];
    let log_file = &args[3];
    let input = read_stdin()?;
    let Ok(data) = serde_json::from_str::<Value>(&input) else {
        println!("SKIP");
        return Ok(());
    };

    let file_path = nested_str(&data, "tool_input.file_path").unwrap_or_default();
    let new_string = nested_str(&data, "tool_input.new_string").unwrap_or_default();
    if file_path.is_empty() || new_string.is_empty() {
        println!("SKIP");
        return Ok(());
    }

    if !is_clean_rust_fast_path(&file_path, &new_string, base_limit) {
        println!("FALLBACK");
        return Ok(());
    }

    let history = post_edit_history_signals(log_file, session, agent, &file_path);
    let warnings = history
        .as_ref()
        .map(|signals| post_edit_history_warnings(log_file, &file_path, signals))
        .unwrap_or_default();

    if warnings.is_empty() && write_fast_log_event(log_file, "pass", "", &file_path).is_ok() {
        println!("FAST_LOGGED");
    } else if !warnings.is_empty() {
        match build_fast_warning_output(log_file, &file_path, &warnings, history.as_ref()) {
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

pub fn post_write_fast_check(args: &[String]) -> Result {
    if args.len() < 3 {
        return Err(
            "Usage: vg-helper post-write-fast-check <base-limit> <max-scan-files> <log-file>"
                .into(),
        );
    }

    let base_limit = args[0].parse::<usize>().unwrap_or(800);
    let max_scan_files = args[1].parse::<usize>().unwrap_or(5000);
    let log_file = &args[2];
    let input = read_stdin()?;
    let Ok(data) = serde_json::from_str::<Value>(&input) else {
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

fn read_stdin() -> io::Result<String> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    Ok(input)
}

fn nested_str(data: &Value, path: &str) -> Option<String> {
    let mut node = data;
    for key in path.split('.') {
        node = node.get(key)?;
    }
    node.as_str().map(str::to_string)
}

fn basename_lower(path: &str) -> String {
    let real = fs::canonicalize(path).unwrap_or_else(|_| PathBuf::from(path));
    real.file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
}

fn is_test_infra_path(path: &str) -> bool {
    let name = basename_lower(path);
    matches!(
        name.as_str(),
        "conftest.py" | "pytest.ini" | ".coveragerc" | "setup.cfg"
    ) || name.starts_with("jest.config.")
        || name.starts_with("vitest.config.")
        || name.starts_with("karma.config.")
        || name.starts_with("babel.config.")
}

fn is_source_path(path: &str) -> bool {
    matches!(
        Path::new(path).extension().and_then(|s| s.to_str()),
        Some(
            "rs" | "py"
                | "ts"
                | "js"
                | "mjs"
                | "cjs"
                | "tsx"
                | "jsx"
                | "go"
                | "java"
                | "kt"
                | "swift"
                | "rb"
        )
    )
}

fn is_pre_edit_u16_source(path: &str) -> bool {
    matches!(
        Path::new(path).extension().and_then(|s| s.to_str()),
        Some("rs" | "ts" | "tsx" | "js" | "jsx" | "py" | "go")
    )
}

fn is_test_path(path: &str) -> bool {
    path.contains("/tests/")
        || path.contains("/test/")
        || path.contains("/__tests__/")
        || path.contains("/spec/")
        || path.contains("/fixtures/")
        || path.contains("/mocks/")
        || path.contains("/testdata/")
        || path.contains("_test.")
        || path.contains(".test.")
        || path.contains(".spec.")
        || path.contains("_test.rs")
        || path.contains("/test_")
}

fn is_allowed_new_file(path: &str) -> bool {
    let basename = Path::new(path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    let lower = basename.to_ascii_lowercase();
    matches!(
        Path::new(&lower).extension().and_then(|s| s.to_str()),
        Some(
            "md" | "txt"
                | "json"
                | "yaml"
                | "yml"
                | "toml"
                | "lock"
                | "css"
                | "html"
                | "svg"
                | "png"
                | "jpg"
                | "sh"
        )
    ) || lower.contains(".test.")
        || lower.contains(".spec.")
        || lower.contains("_test.")
        || lower.contains("_spec.")
        || lower.starts_with("test_")
        || lower.starts_with("spec_")
        || lower == ".gitignore"
        || lower.starts_with(".env")
        || basename == "Makefile"
        || basename == "Dockerfile"
        || is_test_path(path)
}

fn count_lines(content: &str) -> usize {
    if content.is_empty() {
        0
    } else {
        content.matches('\n').count() + usize::from(!content.ends_with('\n'))
    }
}

fn is_clean_rust_fast_path(file_path: &str, new_string: &str, base_limit: usize) -> bool {
    if !file_path.ends_with(".rs") || is_test_path(file_path) {
        return false;
    }
    if new_string.contains(".unwrap(")
        || new_string.contains(".expect(")
        || has_let_underscore_assign(new_string)
        || new_string.contains(".db\"")
        || new_string.contains(".sqlite\"")
        || new_string.contains("todo!(")
        || new_string.contains("unimplemented!(")
        || new_string.contains("panic!(\"not implemented")
    {
        return false;
    }
    if count_lines(new_string) > 200 {
        return false;
    }
    if Path::new(file_path).is_file()
        && count_file_lines(file_path).is_some_and(|lines| lines > base_limit)
    {
        return false;
    }
    true
}

fn is_clean_rust_write_fast_path(file_path: &str, content: &str, base_limit: usize) -> bool {
    if !file_path.ends_with(".rs") || is_test_path(file_path) {
        return false;
    }
    if count_lines(content) > base_limit {
        return false;
    }
    if content.contains("todo!(")
        || content.contains("unimplemented!(")
        || content.contains("panic!(\"not implemented")
    {
        return false;
    }
    !has_meaningful_rust_definition(content)
}

fn has_meaningful_rust_definition(content: &str) -> bool {
    for line in content.lines() {
        let line = line.trim_start();
        let line = line
            .strip_prefix("pub ")
            .or_else(|| line.strip_prefix("pub(crate) "))
            .or_else(|| line.strip_prefix("pub(super) "))
            .unwrap_or(line)
            .trim_start();
        for keyword in ["struct", "enum", "trait", "union", "fn"] {
            let Some(rest) = line.strip_prefix(keyword) else {
                continue;
            };
            let name = rest
                .trim_start()
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                .collect::<String>();
            if name.len() > 3
                && !matches!(
                    name.as_str(),
                    "main" | "test" | "init" | "self" | "impl" | "type" | "move" | "async"
                )
                && !name.starts_with('_')
            {
                return true;
            }
        }
    }
    false
}

fn has_let_underscore_assign(content: &str) -> bool {
    content.lines().any(|line| {
        let trimmed = line.trim_start();
        let Some(rest) = trimmed.strip_prefix("let") else {
            return false;
        };
        let rest = rest.trim_start();
        let Some(rest) = rest.strip_prefix('_') else {
            return false;
        };
        rest.trim_start().starts_with('=')
    })
}

fn count_file_lines(file_path: &str) -> Option<usize> {
    let file = File::open(file_path).ok()?;
    let mut reader = io::BufReader::new(file);
    let mut buf = String::new();
    reader.read_to_string(&mut buf).ok()?;
    Some(count_lines(&buf))
}

fn read_lossy_file(file_path: &str) -> io::Result<String> {
    let bytes = fs::read(file_path)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn find_project_dir(file_path: &str) -> Option<PathBuf> {
    let mut dir = absolute_parent(file_path)?;
    loop {
        if dir.join(".git").exists() {
            return Some(dir);
        }
        let parent = dir.parent()?.to_path_buf();
        if parent == dir {
            return None;
        }
        dir = parent;
    }
}

enum SameNameScan {
    Clean,
    Duplicate,
    TooLarge,
}

fn scan_same_name_duplicate(project_dir: &Path, file_path: &str, max_files: usize) -> SameNameScan {
    let Some(basename) = Path::new(file_path).file_name().and_then(|s| s.to_str()) else {
        return SameNameScan::Clean;
    };
    let target_abs = absolute_path(file_path);
    let mut file_count = 0usize;
    scan_same_name_dir(
        project_dir,
        basename,
        &target_abs,
        max_files,
        &mut file_count,
    )
}

fn scan_same_name_dir(
    dir: &Path,
    basename: &str,
    target_abs: &Path,
    max_files: usize,
    file_count: &mut usize,
) -> SameNameScan {
    let Ok(entries) = fs::read_dir(dir) else {
        return SameNameScan::Clean;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() {
            if should_skip_scan_dir(&path) {
                continue;
            }
            match scan_same_name_dir(&path, basename, target_abs, max_files, file_count) {
                SameNameScan::Clean => {}
                other => return other,
            }
        } else if file_type.is_file() {
            *file_count += 1;
            if *file_count > max_files {
                return SameNameScan::TooLarge;
            }
            if path.file_name().and_then(|s| s.to_str()) == Some(basename)
                && absolute_path(path.to_string_lossy().as_ref()) != target_abs
                && !is_test_path(path.to_string_lossy().as_ref())
            {
                return SameNameScan::Duplicate;
            }
        }
    }
    SameNameScan::Clean
}

fn should_skip_scan_dir(path: &Path) -> bool {
    matches!(
        path.file_name().and_then(|s| s.to_str()),
        Some(
            "node_modules"
                | ".git"
                | "target"
                | "vendor"
                | "dist"
                | "build"
                | "__pycache__"
                | ".venv"
                | "tests"
                | "__tests__"
                | "test"
                | "spec"
        )
    )
}

fn absolute_path(path: &str) -> PathBuf {
    let path = Path::new(path);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    }
}

#[derive(Default)]
struct PostEditHistorySignals {
    churn_count: usize,
    warn_count: usize,
    w15_count: usize,
    overlap: Option<OverlapSignal>,
}

struct OverlapSignal {
    session: String,
    agent: String,
    hook: String,
    tool: String,
}

fn post_edit_history_signals(
    log_file: &str,
    session: &str,
    agent: &str,
    file_path: &str,
) -> Option<PostEditHistorySignals> {
    let Ok(lines) = read_tail_lines(log_file, POST_EDIT_HISTORY_LINES) else {
        return None;
    };
    let events = lines
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .collect::<Vec<_>>();
    if events.is_empty() {
        return None;
    }

    let churn_count = events
        .iter()
        .filter(|e| e.get(field::SESSION).and_then(Value::as_str) == Some(session))
        .filter(|e| e.get(field::TOOL).and_then(Value::as_str) == Some(tool::EDIT))
        .filter(|e| {
            e.get(field::DETAIL)
                .and_then(Value::as_str)
                .is_some_and(|detail| detail.contains(file_path))
        })
        .count();
    let warn_count = events
        .iter()
        .filter(|e| e.get(field::SESSION).and_then(Value::as_str) == Some(session))
        .filter(|e| e.get(field::HOOK).and_then(Value::as_str) == Some(hook::POST_EDIT_GUARD))
        .filter(|e| e.get(field::DECISION).and_then(Value::as_str) == Some("warn"))
        .filter(|e| first_detail_path(e) == file_path)
        .count();

    Some(PostEditHistorySignals {
        churn_count,
        warn_count,
        w15_count: consecutive_post_edit_count(&events, session, file_path),
        overlap: recent_overlap(&events, session, agent, file_path),
    })
}

fn consecutive_post_edit_count(events: &[Value], session: &str, file_path: &str) -> usize {
    let mut count = 0;
    for event in events.iter().rev().filter(|e| {
        e.get(field::SESSION).and_then(Value::as_str) == Some(session)
            && e.get(field::TOOL).and_then(Value::as_str) == Some(tool::EDIT)
            && e.get(field::HOOK).and_then(Value::as_str) == Some(hook::POST_EDIT_GUARD)
    }) {
        if first_detail_path(event) == file_path {
            count += 1;
        } else {
            break;
        }
    }
    count
}

fn recent_overlap(
    events: &[Value],
    session: &str,
    agent: &str,
    file_path: &str,
) -> Option<OverlapSignal> {
    let normalized_file = normalize_path(file_path);
    let cutoff = now_unix_secs().saturating_sub(30 * 60);
    let mut last = None;
    for e in events {
        if !matches!(
            e.get(field::TOOL).and_then(Value::as_str),
            Some(tool::EDIT) | Some(tool::WRITE)
        ) {
            continue;
        }
        let same_session = e.get(field::SESSION).and_then(Value::as_str) == Some(session);
        let other_agent = e.get("agent").and_then(Value::as_str).unwrap_or("") != agent;
        if same_session && !other_agent {
            continue;
        }
        let detail_path = first_detail_path(e);
        if detail_path != file_path && normalize_path(detail_path) != normalized_file {
            continue;
        }
        let Some(ts) = e
            .get(field::TS)
            .and_then(Value::as_str)
            .and_then(parse_iso_ts)
        else {
            continue;
        };
        if ts < cutoff {
            continue;
        }
        last = Some(OverlapSignal {
            session: e
                .get(field::SESSION)
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_string(),
            agent: e
                .get("agent")
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_string(),
            hook: e
                .get(field::HOOK)
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_string(),
            tool: e
                .get(field::TOOL)
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_string(),
        });
    }
    last
}

fn normalize_path(path: &str) -> String {
    let path = path.trim();
    if path.is_empty() {
        return String::new();
    }
    let path_buf = if Path::new(path).is_absolute() {
        PathBuf::from(path)
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    };
    let canonical = std::fs::canonicalize(&path_buf).unwrap_or(path_buf);
    canonical.to_string_lossy().to_string()
}

fn first_detail_path(event: &Value) -> &str {
    event
        .get(field::DETAIL)
        .and_then(Value::as_str)
        .unwrap_or("")
        .split("||")
        .next()
        .unwrap_or("")
        .trim()
}

fn read_tail_lines(path: &str, max_lines: usize) -> io::Result<String> {
    let mut file = File::open(path)?;
    let mut pos = file.metadata()?.len();
    let mut buf = Vec::new();
    let mut newline_count = 0usize;

    while pos > 0 && newline_count <= max_lines {
        let read_size = usize::min(8192, pos as usize);
        pos -= read_size as u64;
        file.seek(SeekFrom::Start(pos))?;
        let mut chunk = vec![0u8; read_size];
        file.read_exact(&mut chunk)?;
        newline_count += chunk.iter().filter(|b| **b == b'\n').count();
        chunk.extend_from_slice(&buf);
        buf = chunk;
    }

    if newline_count > max_lines {
        let mut seen = 0usize;
        let mut start = 0usize;
        for (idx, byte) in buf.iter().enumerate().rev() {
            if *byte == b'\n' {
                seen += 1;
                if seen == max_lines + 1 {
                    start = idx + 1;
                    break;
                }
            }
        }
        buf = buf[start..].to_vec();
    }

    Ok(String::from_utf8_lossy(&buf).into_owned())
}

fn post_edit_history_warnings(
    log_file: &str,
    file_path: &str,
    signals: &PostEditHistorySignals,
) -> String {
    let mut warnings = Vec::new();
    let basename = Path::new(file_path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(file_path);

    if signals.churn_count >= 20 {
        warnings.push(format!(
            "[CHURN CRITICAL] [review] [this-file] OBSERVATION: {basename} has been edited {} times - possible edit->fail->fix loop\nFIX: Stop current direction, review full build output, re-examine root cause (W-02)\nDO NOT: Continue editing this file until root cause is confirmed",
            signals.churn_count
        ));
        let _ = write_fast_log_event(
            log_file,
            "escalate",
            &format!("churn {}x critical", signals.churn_count),
            file_path,
        );
    } else if signals.churn_count >= 10 {
        warnings.push(format!(
            "[CHURN WARNING] [info] [this-file] OBSERVATION: {basename} has been edited {} times, possible correction loop\nFIX: Run full build to see the complete picture, or use /vibeguard:learn to extract patterns\nDO NOT: Take any action - monitor and decide whether to continue",
            signals.churn_count
        ));
        let _ = write_fast_log_event(
            log_file,
            "escalate",
            &format!("churn {}x warning", signals.churn_count),
            file_path,
        );
    } else if signals.churn_count >= 5 {
        warnings.push(format!(
            "[CHURN] [info] [this-file] OBSERVATION: {basename} has been edited {} times\nFIX: Check if you are in a correction loop before continuing\nDO NOT: Take any action - this is informational only",
            signals.churn_count
        ));
        let _ = write_fast_log_event(
            log_file,
            "correction",
            &format!("churn {}x", signals.churn_count),
            file_path,
        );
    }

    if let Some(overlap) = &signals.overlap {
        let agent = if overlap.agent.is_empty() {
            "unknown"
        } else {
            &overlap.agent
        };
        warnings.push(format!(
            "[W-14] [review] [this-file] OBSERVATION: another session or agent recently touched {basename} ({} via {}, session {}, agent {})\nFIX: Confirm file ownership before continuing; prefer a dedicated worktree or single-owner merge path\nDO NOT: Continue parallel/background edits to this file without explicit ownership",
            overlap.tool, overlap.hook, overlap.session, agent
        ));
        let _ = write_fast_log_event(
            log_file,
            "warn",
            &format!(
                "w14 overlap recent session {} agent {agent}",
                overlap.session
            ),
            file_path,
        );
    }

    if signals.w15_count >= 2 {
        let total = signals.w15_count + 1;
        warnings.push(format!(
            "[W-15] [review] [this-file] OBSERVATION: {total} consecutive edits to {basename} with no edits to other files in between (low-info loop suspect)\nFIX: Pause - are these {total} edits solving the same problem? If change scope shrinks each round, report a blocker instead of continuing to round {}\nDO NOT: Toggle between equivalent rewrites; do not continue same-direction micro-tuning without reporting",
            total + 1
        ));
        let _ = write_fast_log_event(
            log_file,
            "warn",
            &format!("w15 consecutive {total}x"),
            file_path,
        );
    }

    warnings.join("\n---\n")
}

fn build_fast_warning_output(
    log_file: &str,
    file_path: &str,
    warnings: &str,
    history: Option<&PostEditHistorySignals>,
) -> io::Result<String> {
    let warn_count = history.map(|s| s.warn_count).unwrap_or(0);
    let (decision, final_warnings) = if warn_count >= 3 {
        (
            "escalate",
            format!(
                "[ESCALATE] [review] [this-file] OBSERVATION: this file has triggered {warn_count} warnings - user intervention recommended\nFIX: Stop and review the warnings below before continuing\nDO NOT: Continue editing this file without reviewing all warnings\n---\n{warnings}"
            ),
        )
    } else {
        ("warn", warnings.to_string())
    };
    write_fast_log_event(log_file, decision, &final_warnings, file_path)?;
    let prefix = if decision == "escalate" {
        "VIBEGUARD upgrade warning"
    } else {
        "VIBEGUARD quality warning"
    };
    let result = serde_json::json!({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": format!("{prefix}:{}", final_warnings),
        }
    });
    Ok(serde_json::to_string(&result).unwrap_or_else(|_| "{}".to_string()))
}

fn write_fast_log_event(
    log_file: &str,
    decision: &str,
    reason: &str,
    file_path: &str,
) -> io::Result<()> {
    write_log_event(
        log_file,
        "post-edit-guard",
        "Edit",
        decision,
        reason,
        file_path,
    )
}

fn write_log_event(
    log_file: &str,
    hook_name: &str,
    tool_name: &str,
    decision: &str,
    reason: &str,
    detail: &str,
) -> io::Result<()> {
    let session = env::var("VIBEGUARD_SESSION_ID").unwrap_or_else(|_| "unknown".to_string());
    let cli = env::var("VIBEGUARD_CLI").ok();
    let agent = env::var("VIBEGUARD_AGENT_TYPE").ok();
    let ts = format_unix_secs_utc(now_unix_secs());
    let mut event = serde_json::json!({
        "schema_version": 1,
        "ts": ts,
        "session": session,
        "hook": hook_name,
        "tool": tool_name,
        "decision": decision,
        "reason": reason,
        "detail": detail,
    });
    if let Some(cli) = cli.filter(|s| !s.is_empty()) {
        event["cli"] = serde_json::Value::String(cli);
    }
    if let Some(agent) = agent.filter(|s| !s.is_empty()) {
        event["agent"] = serde_json::Value::String(agent);
    }
    let line = serde_json::to_string(&event).unwrap_or_else(|_| "{}".to_string());
    append_jsonl(Path::new(log_file), &line)?;

    if let Ok(log_dir) = env::var("VIBEGUARD_LOG_DIR") {
        let global = Path::new(&log_dir).join("events.jsonl");
        if global != Path::new(log_file) {
            append_jsonl(&global, &line)?;
        }
    }
    Ok(())
}

fn append_jsonl(path: &Path, line: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let existed = path.exists();
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    file.write_all(line.as_bytes())?;
    file.write_all(b"\n")?;
    if !existed {
        set_owner_only(path);
    }
    Ok(())
}

#[cfg(unix)]
fn set_owner_only(path: &Path) {
    if let Ok(metadata) = fs::metadata(path) {
        let mut permissions = metadata.permissions();
        permissions.set_mode(0o600);
        let _ = fs::set_permissions(path, permissions);
    }
}

#[cfg(not(unix))]
fn set_owner_only(_path: &Path) {}

fn project_u16_limit(file_path: &str, base_limit: usize) -> usize {
    let mut dir = absolute_parent(file_path);
    while let Some(current) = dir {
        if current.join(".git").exists() {
            return claude_u16_limit(&current.join("CLAUDE.md"), file_path, base_limit);
        }
        dir = current.parent().map(Path::to_path_buf);
    }
    base_limit
}

fn absolute_parent(file_path: &str) -> Option<PathBuf> {
    let path = Path::new(file_path);
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().ok()?.join(path)
    };
    absolute.parent().map(Path::to_path_buf)
}

fn claude_u16_limit(path: &Path, file_path: &str, base_limit: usize) -> usize {
    let Ok(text) = fs::read_to_string(path) else {
        return base_limit;
    };
    let mut limit = base_limit;
    for line in text.lines().filter(|line| line.contains("U-16 exempt")) {
        for (pattern, value) in backtick_limit_pairs(line) {
            if glob_match(&pattern, file_path) {
                limit = limit.max(value);
            }
        }
    }
    limit
}

fn backtick_limit_pairs(line: &str) -> Vec<(String, usize)> {
    let mut pairs = Vec::new();
    let mut rest = line;
    while let Some(start) = rest.find('`') {
        rest = &rest[start + 1..];
        let Some(end) = rest.find('`') else {
            break;
        };
        let pattern = rest[..end].to_string();
        rest = &rest[end + 1..];
        let digits = rest
            .chars()
            .skip_while(|c| !c.is_ascii_digit())
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>();
        if let Ok(limit) = digits.parse::<usize>() {
            pairs.push((pattern, limit));
        }
    }
    pairs
}

fn glob_match(pattern: &str, value: &str) -> bool {
    glob_match_bytes(pattern.as_bytes(), value.as_bytes())
        || glob_match_bytes(pattern.as_bytes(), value.replace('\\', "/").as_bytes())
}

fn glob_match_bytes(pattern: &[u8], value: &[u8]) -> bool {
    let (mut pi, mut vi) = (0, 0);
    let (mut star, mut star_vi) = (None, 0);
    while vi < value.len() {
        if pi < pattern.len() && (pattern[pi] == b'?' || pattern[pi] == value[vi]) {
            pi += 1;
            vi += 1;
        } else if pi < pattern.len() && pattern[pi] == b'*' {
            star = Some(pi);
            star_vi = vi;
            pi += 1;
        } else if let Some(star_pi) = star {
            pi = star_pi + 1;
            star_vi += 1;
            vi = star_vi;
        } else {
            return false;
        }
    }
    while pi < pattern.len() && pattern[pi] == b'*' {
        pi += 1;
    }
    pi == pattern.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn count_lines_matches_hook_contract() {
        assert_eq!(count_lines(""), 0);
        assert_eq!(count_lines("a"), 1);
        assert_eq!(count_lines("a\n"), 1);
        assert_eq!(count_lines("a\nb"), 2);
    }

    #[test]
    fn test_infra_path_matches_known_config_names() {
        assert!(is_test_infra_path("/tmp/conftest.py"));
        assert!(is_test_infra_path("/tmp/jest.config.ts"));
        assert!(!is_test_infra_path("/tmp/config.json"));
    }

    #[test]
    fn source_and_allowed_paths_match_shell_rules() {
        assert!(is_source_path("src/lib.rs"));
        assert!(!is_source_path("README.md"));
        assert!(is_allowed_new_file("README.md"));
        assert!(is_allowed_new_file("/repo/tests/helper.py"));
        assert!(!is_allowed_new_file("src/new_service.py"));
    }

    #[test]
    fn glob_match_supports_simple_exemptions() {
        assert!(glob_match("src/*.rs", "src/lib.rs"));
        assert!(glob_match("*/generated/*.py", "pkg/generated/out.py"));
        assert!(!glob_match("src/*.rs", "src/lib.py"));
    }

    #[test]
    fn post_edit_fast_path_accepts_clean_rust_only() {
        assert!(is_clean_rust_fast_path(
            "src/main.rs",
            "fn main() {\n    println!(\"hello\");\n}",
            800
        ));
        assert!(!is_clean_rust_fast_path(
            "src/main.rs",
            "let value = maybe.unwrap();",
            800
        ));
        assert!(!is_clean_rust_fast_path(
            "src/main.rs",
            "let _ = sender.send(msg);",
            800
        ));
        assert!(!is_clean_rust_fast_path(
            "src/main.ts",
            "console.log(value);",
            800
        ));
    }

    #[test]
    fn post_write_fast_path_accepts_only_small_rust_without_defs() {
        assert!(is_clean_rust_write_fast_path(
            "src/new_file.rs",
            "fn main() {\n    println!(\"hello\");\n}\n",
            800
        ));
        assert!(!is_clean_rust_write_fast_path(
            "src/lib.rs",
            "pub struct UserService;\n",
            800
        ));
        assert!(!is_clean_rust_write_fast_path(
            "src/lib.rs",
            "todo!()\n",
            800
        ));
        assert!(!is_clean_rust_write_fast_path(
            "src/lib.py",
            "print('hello')\n",
            800
        ));
    }

    #[test]
    fn post_edit_fast_path_falls_back_for_history_signals() {
        let events = vec![
            serde_json::json!({
                "session": "current",
                "tool": "Edit",
                "hook": "post-edit-guard",
                "detail": "src/main.rs"
            }),
            serde_json::json!({
                "session": "current",
                "tool": "Edit",
                "hook": "post-edit-guard",
                "detail": "src/main.rs"
            }),
        ];
        assert_eq!(
            consecutive_post_edit_count(&events, "current", "src/main.rs"),
            2
        );
        assert!(
            recent_overlap(
                &[serde_json::json!({
                    "ts": format_unix_secs_utc(now_unix_secs()),
                    "session": "other",
                    "agent": "codex",
                    "tool": "Edit",
                    "detail": "/tmp/main.rs"
                })],
                "current",
                "codex",
                "/tmp/main.rs"
            )
            .is_some()
        );
    }
}
