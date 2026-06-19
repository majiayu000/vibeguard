use serde_json::Value;
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use crate::time_utils::{format_unix_secs_utc, now_unix_millis, now_unix_secs};

pub(crate) fn read_stdin() -> io::Result<String> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    Ok(input)
}

pub(crate) fn nested_str(data: &Value, path: &str) -> Option<String> {
    let mut node = data;
    for key in path.split('.') {
        node = node.get(key)?;
    }
    node.as_str().map(str::to_string)
}

pub(crate) fn truncate_chars(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

fn basename_lower(path: &str) -> String {
    let real = fs::canonicalize(path).unwrap_or_else(|_| PathBuf::from(path));
    real.file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
}

pub(crate) fn is_test_infra_path(path: &str) -> bool {
    let name = basename_lower(path);
    matches!(
        name.as_str(),
        "conftest.py" | "pytest.ini" | ".coveragerc" | "setup.cfg"
    ) || name.starts_with("jest.config.")
        || name.starts_with("vitest.config.")
        || name.starts_with("karma.config.")
        || name.starts_with("babel.config.")
}

pub(crate) fn is_source_path(path: &str) -> bool {
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

pub(crate) fn is_pre_edit_u16_source(path: &str) -> bool {
    matches!(
        Path::new(path).extension().and_then(|s| s.to_str()),
        Some("rs" | "ts" | "tsx" | "js" | "jsx" | "py" | "go")
    )
}

pub(crate) fn is_test_path(path: &str) -> bool {
    let normalized = path.replace('\\', "/").to_ascii_lowercase();
    let basename = normalized.rsplit('/').next().unwrap_or("");
    has_path_segment(&normalized, "tests")
        || has_path_segment(&normalized, "test")
        || has_path_segment(&normalized, "__tests__")
        || has_path_segment(&normalized, "spec")
        || has_path_segment(&normalized, "fixtures")
        || has_path_segment(&normalized, "mocks")
        || has_path_segment(&normalized, "testdata")
        || has_path_segment(&normalized, "examples")
        || has_path_segment(&normalized, "benches")
        || has_path_segment_with_prefix(&normalized, "test_")
        || basename == "tests.rs"
        || basename == "test_helpers.rs"
        || basename.starts_with("test_")
        || basename.contains("_test.")
        || basename.contains(".test.")
        || basename.contains(".spec.")
        || basename.ends_with("_test.rs")
}

fn has_path_segment(path: &str, segment: &str) -> bool {
    path.split('/').any(|part| part == segment)
}

fn has_path_segment_with_prefix(path: &str, prefix: &str) -> bool {
    path.split('/').any(|part| part.starts_with(prefix))
}

pub(crate) fn is_allowed_new_file(path: &str) -> bool {
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

pub(crate) fn count_lines(content: &str) -> usize {
    if content.is_empty() {
        0
    } else {
        content.matches('\n').count() + usize::from(!content.ends_with('\n'))
    }
}

pub(crate) fn is_clean_rust_fast_path(
    file_path: &str,
    new_string: &str,
    base_limit: usize,
) -> bool {
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

pub(crate) fn is_clean_rust_write_fast_path(
    file_path: &str,
    content: &str,
    base_limit: usize,
) -> bool {
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
        let line = strip_rust_definition_modifiers(line.trim_start());
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

fn strip_rust_definition_modifiers(mut line: &str) -> &str {
    loop {
        line = line.trim_start();
        if let Some(rest) = line.strip_prefix("pub ") {
            line = rest;
            continue;
        }
        if let Some(rest) = line.strip_prefix("pub(crate) ") {
            line = rest;
            continue;
        }
        if let Some(rest) = line.strip_prefix("pub(super) ") {
            line = rest;
            continue;
        }
        if let Some(rest) = line.strip_prefix("pub(") {
            if let Some(end) = rest.find(')') {
                line = &rest[end + 1..];
                continue;
            }
        }
        if let Some(rest) = line.strip_prefix("async ") {
            line = rest;
            continue;
        }
        if let Some(rest) = line.strip_prefix("const ") {
            line = rest;
            continue;
        }
        if let Some(rest) = line.strip_prefix("unsafe ") {
            line = rest;
            continue;
        }
        return line;
    }
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

pub(crate) fn read_lossy_file(file_path: &str) -> io::Result<String> {
    let bytes = fs::read(file_path)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

pub(crate) fn first_detail_path(event: &Value) -> &str {
    event
        .get(crate::event_schema::field::DETAIL)
        .and_then(Value::as_str)
        .unwrap_or("")
        .split("||")
        .next()
        .unwrap_or("")
        .trim()
}

pub(crate) fn write_log_event(
    log_file: &str,
    hook_name: &str,
    tool_name: &str,
    decision: &str,
    reason: &str,
    detail: &str,
) -> io::Result<()> {
    let session = env::var("VIBEGUARD_SESSION_ID").unwrap_or_else(|_| "unknown".to_string());
    let ts = format_unix_secs_utc(now_unix_secs());
    let mut event = serde_json::json!({
        "schema_version": 1,
        "ts": ts,
        "session": session,
        "hook": hook_name,
        "tool": tool_name,
        "decision": decision,
        "status": decision,
        "reason": reason,
        "detail": detail,
    });
    if let Some(duration_ms) = runtime_hook_duration_ms() {
        event[crate::event_schema::field::DURATION_MS] = serde_json::Value::from(duration_ms);
    }
    for (env_name, field_name) in [
        ("VIBEGUARD_CLI", crate::event_schema::field::CLI),
        ("VIBEGUARD_AGENT_TYPE", crate::event_schema::field::AGENT),
        ("VIBEGUARD_CLIENT", crate::event_schema::field::CLIENT),
        (
            "VIBEGUARD_CLIENT_VARIANT",
            crate::event_schema::field::CLIENT_VARIANT,
        ),
        ("VIBEGUARD_WRAPPER", crate::event_schema::field::WRAPPER),
        (
            "VIBEGUARD_SOURCE_CONFIG",
            crate::event_schema::field::SOURCE_CONFIG,
        ),
        (
            "VIBEGUARD_HOOK_PROTOCOL_VERSION",
            crate::event_schema::field::HOOK_PROTOCOL_VERSION,
        ),
        (
            "VIBEGUARD_CALLER_EVIDENCE",
            crate::event_schema::field::CALLER_EVIDENCE,
        ),
    ] {
        if let Ok(value) = env::var(env_name) {
            if !value.is_empty() {
                event[field_name] = serde_json::Value::String(value);
            }
        }
    }
    let line = serde_json::to_string(&event).unwrap_or_else(|_| "{}".to_string());
    append_jsonl(Path::new(log_file), &line)?;

    if let Ok(log_dir) = env::var("VIBEGUARD_LOG_DIR") {
        let global = Path::new(&log_dir).join("events.jsonl");
        if global != Path::new(log_file) {
            append_jsonl(&global, &line).map_err(|err| {
                let path = global.display();
                let msg = format!("global JSONL mirror append failed for {path}: {err}");
                io::Error::new(err.kind(), msg)
            })?;
        }
    }
    Ok(())
}

fn runtime_hook_duration_ms() -> Option<u64> {
    let start_ms = env::var("VIBEGUARD_HOOK_START_MS")
        .ok()?
        .parse::<u64>()
        .ok()?;
    Some(now_unix_millis().saturating_sub(start_ms))
}

pub(crate) fn append_jsonl(path: &Path, line: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let existed = path.exists();
    let _lock = JsonlAppendLock::acquire(path)?;
    if existed {
        set_owner_only(path);
    }
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file = options.open(path)?;
    let mut entry = String::with_capacity(line.len() + 1);
    entry.push_str(line);
    entry.push('\n');
    file.write_all(entry.as_bytes())?;
    set_owner_only(path);
    Ok(())
}

struct JsonlAppendLock {
    lock_dir: PathBuf,
}

impl JsonlAppendLock {
    fn acquire(path: &Path) -> io::Result<Self> {
        let mut lock_dir = path.as_os_str().to_os_string();
        lock_dir.push(".lock.d");
        let lock_dir = PathBuf::from(lock_dir);
        let max_attempts = jsonl_lock_attempts();
        let sleep_duration = jsonl_lock_sleep_duration();

        for attempt in 0..max_attempts {
            match fs::create_dir(&lock_dir) {
                Ok(()) => {
                    return Ok(Self { lock_dir });
                }
                Err(err) if err.kind() == io::ErrorKind::AlreadyExists => {
                    if remove_stale_jsonl_lock(&lock_dir)? {
                        match fs::create_dir(&lock_dir) {
                            Ok(()) => return Ok(Self { lock_dir }),
                            Err(err) if err.kind() == io::ErrorKind::AlreadyExists => {}
                            Err(err) => return Err(err),
                        }
                    }
                    if attempt + 1 < max_attempts && !sleep_duration.is_zero() {
                        std::thread::sleep(sleep_duration);
                    }
                }
                Err(err) => return Err(err),
            }
        }

        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            format!(
                "timed out waiting for JSONL append lock after {max_attempts} attempts: {}; recovery: if no VibeGuard process is active, remove this stale lock directory",
                lock_dir.display()
            ),
        ))
    }
}

fn remove_stale_jsonl_lock(lock_dir: &Path) -> io::Result<bool> {
    let stale_after = jsonl_lock_stale_duration();
    let Ok(metadata) = fs::metadata(lock_dir) else {
        return Ok(false);
    };
    if !metadata.is_dir() {
        return Ok(false);
    }
    if stale_after.is_zero() {
        return remove_jsonl_lock_dir(lock_dir);
    }
    let Ok(modified) = metadata.modified() else {
        return Ok(false);
    };
    let Ok(age) = SystemTime::now().duration_since(modified) else {
        return Ok(false);
    };
    if age < stale_after {
        return Ok(false);
    }

    remove_jsonl_lock_dir(lock_dir)
}

fn remove_jsonl_lock_dir(lock_dir: &Path) -> io::Result<bool> {
    match fs::remove_dir(lock_dir) {
        Ok(()) => Ok(true),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(true),
        Err(err) if err.kind() == io::ErrorKind::DirectoryNotEmpty => Ok(false),
        Err(err) => Err(err),
    }
}

fn jsonl_lock_attempts() -> usize {
    env::var("VIBEGUARD_LOG_LOCK_ATTEMPTS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .map(|value| value.max(1))
        .unwrap_or(100)
}

fn jsonl_lock_sleep_duration() -> Duration {
    env::var("VIBEGUARD_LOG_LOCK_SLEEP_SECONDS")
        .ok()
        .and_then(|value| value.parse::<f64>().ok())
        .filter(|value| value.is_finite() && *value >= 0.0)
        .map(Duration::from_secs_f64)
        .unwrap_or_else(|| Duration::from_millis(10))
}

fn jsonl_lock_stale_duration() -> Duration {
    env::var("VIBEGUARD_LOG_LOCK_STALE_SECONDS")
        .ok()
        .and_then(|value| value.parse::<f64>().ok())
        .filter(|value| value.is_finite() && *value >= 0.0)
        .map(Duration::from_secs_f64)
        .unwrap_or_else(|| Duration::from_secs(10 * 60))
}

impl Drop for JsonlAppendLock {
    fn drop(&mut self) {
        let _ = fs::remove_dir(&self.lock_dir);
    }
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

pub(crate) fn project_u16_limit(file_path: &str, base_limit: usize) -> usize {
    let mut dir = absolute_parent(file_path);
    while let Some(current) = dir {
        if current.join(".git").exists() {
            return claude_u16_limit(&current.join("CLAUDE.md"), file_path, &current, base_limit);
        }
        dir = current.parent().map(Path::to_path_buf);
    }
    base_limit
}

pub(crate) fn absolute_parent(file_path: &str) -> Option<PathBuf> {
    let path = Path::new(file_path);
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().ok()?.join(path)
    };
    absolute.parent().map(Path::to_path_buf)
}

fn claude_u16_limit(path: &Path, file_path: &str, project_root: &Path, base_limit: usize) -> usize {
    let Ok(text) = fs::read_to_string(path) else {
        return base_limit;
    };
    let mut limit = base_limit;
    for line in text.lines().filter(|line| line.contains("U-16 exempt")) {
        for (pattern, value) in backtick_limit_pairs(line) {
            if u16_pattern_matches(&pattern, file_path, project_root) {
                limit = limit.max(value);
            }
        }
    }
    limit
}

fn u16_pattern_matches(pattern: &str, file_path: &str, project_root: &Path) -> bool {
    if glob_match(pattern, file_path) {
        return true;
    }
    let path = Path::new(file_path);
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        project_root.join(path)
    };
    if let Ok(relative) = absolute.strip_prefix(project_root) {
        let relative = relative.to_string_lossy().replace('\\', "/");
        return glob_match(pattern, &relative);
    }
    false
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

pub(crate) fn glob_match(pattern: &str, value: &str) -> bool {
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
    fn test_path_matches_rust_guard_exclusions() {
        for path in [
            "tests/integration.rs",
            "src/tests.rs",
            "src/test_helpers.rs",
            "src/test_helpers/mod.rs",
            "src/test_utils/helper.rs",
            "examples/demo.rs",
            "benches/throughput.rs",
            "test_root.rs",
            "src/math_test.rs",
            "src/lib.test.rs",
        ] {
            assert!(is_test_path(path), "{path} should be classified as test");
        }
        assert!(!is_test_path("src/contest.rs"));
        assert!(!is_test_path("src/contest_helpers/mod.rs"));
        assert!(!is_test_path("src/prod_helpers.rs"));
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
        assert!(!is_clean_rust_write_fast_path(
            "src/lib.rs",
            "pub async fn fetch_user() {}\n",
            800
        ));
        assert!(!is_clean_rust_write_fast_path(
            "src/lib.rs",
            "pub(crate) unsafe async fn sync_user() {}\n",
            800
        ));
    }

    #[test]
    fn relative_u16_exemption_matches_absolute_project_path() {
        let project_root = std::env::current_dir().unwrap().join("repo-root");
        let file_path = project_root.join("src").join("large.rs");
        assert!(u16_pattern_matches(
            "src/large.rs",
            &file_path.to_string_lossy(),
            &project_root
        ));
        assert!(u16_pattern_matches(
            "src/*.rs",
            &file_path.to_string_lossy(),
            &project_root
        ));
        assert!(!u16_pattern_matches(
            "tests/*.rs",
            &file_path.to_string_lossy(),
            &project_root
        ));
    }

    #[test]
    fn append_jsonl_keeps_concurrent_records_parseable() {
        let temp_dir = std::env::temp_dir().join(format!(
            "vibeguard-jsonl-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let log_file = temp_dir.join("events.jsonl");
        let mut handles = Vec::new();

        for worker in 0..8 {
            let log_file = log_file.clone();
            handles.push(std::thread::spawn(move || {
                for item in 0..50 {
                    let line = serde_json::json!({
                        "worker": worker,
                        "item": item,
                    })
                    .to_string();
                    append_jsonl(&log_file, &line).unwrap();
                }
            }));
        }

        for handle in handles {
            handle.join().unwrap();
        }

        let content = fs::read_to_string(&log_file).unwrap();
        let lines: Vec<&str> = content.lines().collect();
        assert_eq!(lines.len(), 400);
        for line in lines {
            serde_json::from_str::<Value>(line).unwrap();
        }
        assert!(!PathBuf::from(format!("{}.lock.d", log_file.display())).exists());

        let _ = fs::remove_dir_all(temp_dir);
    }
}
