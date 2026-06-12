use std::collections::hash_map::DefaultHasher;
use std::env;
use std::fs;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::setup_support::{home_dir, sha256_text_short};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

const SESSION_TTL: Duration = Duration::from_secs(30 * 60);
const SESSION_CLEANUP_AGE: Duration = Duration::from_secs(120 * 60);

pub(crate) fn run(args: &[String]) -> Result<()> {
    if args.len() > 1 {
        return Err("Usage: vibeguard-runtime wrapper-env [cli]".into());
    }

    let cli = env_nonempty("VIBEGUARD_CLI").unwrap_or_else(|| {
        args.first()
            .filter(|value| !value.trim().is_empty())
            .cloned()
            .unwrap_or_else(|| "unknown".to_string())
    });
    let log_root = log_root();
    let project_root = current_project_root();
    let project_root_text = project_root
        .as_ref()
        .map(|path| path.to_string_lossy().to_string())
        .unwrap_or_else(|| "global".to_string());
    let project_hash = env_nonempty("VIBEGUARD_PROJECT_HASH")
        .unwrap_or_else(|| sha256_text_short(&project_root_text));
    let project_log_dir = env_nonempty("VIBEGUARD_PROJECT_LOG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| log_root.join("projects").join(&project_hash));
    let log_file = env_nonempty("VIBEGUARD_LOG_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| project_log_dir.join("events.jsonl"));

    fs::create_dir_all(&project_log_dir)?;
    if project_root.is_some() {
        let _ = fs::write(
            project_log_dir.join(".project-root"),
            project_root_text.as_bytes(),
        );
    }

    let session_id = env_nonempty("VIBEGUARD_SESSION_ID")
        .unwrap_or_else(|| resolve_session_id(&project_log_dir, &cli, &project_root_text));

    println!("VIBEGUARD_CLI={cli}");
    println!("VIBEGUARD_PROJECT_HASH={project_hash}");
    println!(
        "VIBEGUARD_PROJECT_LOG_DIR={}",
        project_log_dir.to_string_lossy()
    );
    println!("VIBEGUARD_LOG_FILE={}", log_file.to_string_lossy());
    println!("VIBEGUARD_SESSION_ID={session_id}");
    Ok(())
}

fn env_nonempty(name: &str) -> Option<String> {
    env::var(name).ok().filter(|value| !value.trim().is_empty())
}

fn log_root() -> PathBuf {
    env_nonempty("VIBEGUARD_LOG_DIR")
        .map(PathBuf::from)
        .or_else(|| home_dir().map(|home| home.join(".vibeguard")))
        .unwrap_or_else(|| PathBuf::from(".vibeguard"))
}

fn current_project_root() -> Option<PathBuf> {
    project_root_for(&env::current_dir().ok()?)
}

fn project_root_for(start: &Path) -> Option<PathBuf> {
    let mut current = start.to_path_buf();
    loop {
        if current.join(".git").exists() {
            return fs::canonicalize(&current).ok().or(Some(current));
        }
        if !current.pop() {
            return None;
        }
    }
}

fn resolve_session_id(project_log_dir: &Path, cli: &str, project_root: &str) -> String {
    cleanup_old_sessions(project_log_dir);
    let anchor = session_anchor();
    let token = sanitize_token(cli);
    let session_file = project_log_dir.join(format!(".wrapper_session_{token}_{}", anchor.pid));

    if let Some(session_id) = read_recent_session(&session_file, &anchor.start) {
        let _ = write_session_file(&session_file, &anchor.start, &session_id);
        return session_id;
    }

    let session_id = new_session_id(&anchor, project_root);
    let _ = write_session_file(&session_file, &anchor.start, &session_id);
    session_id
}

struct SessionAnchor {
    pid: libc::pid_t,
    start: String,
}

fn session_anchor() -> SessionAnchor {
    let pid = env_nonempty("VIBEGUARD_WRAPPER_PARENT_PID")
        .and_then(|value| parse_pid(&value))
        .unwrap_or_else(|| unsafe { libc::getppid() });
    let start = process_start_token(pid).unwrap_or_else(|| "unknown".to_string());
    SessionAnchor { pid, start }
}

fn parse_pid(value: &str) -> Option<libc::pid_t> {
    let parsed = value.trim().parse::<libc::pid_t>().ok()?;
    (parsed > 1).then_some(parsed)
}

fn read_recent_session(path: &Path, expected_start: &str) -> Option<String> {
    let modified = fs::metadata(path).ok()?.modified().ok()?;
    if modified.elapsed().ok()? > SESSION_TTL {
        return None;
    }
    let contents = fs::read_to_string(path).ok()?;
    let mut lines = contents.lines();
    let first = lines.next()?.trim();
    let session_id = if let Some(second) = lines.next() {
        if first != expected_start {
            return None;
        }
        second.trim().to_string()
    } else {
        first.to_string()
    };
    if session_id.is_empty() {
        None
    } else {
        Some(session_id)
    }
}

fn write_session_file(path: &Path, start: &str, session_id: &str) -> std::io::Result<()> {
    fs::write(path, format!("{start}\n{session_id}\n"))
}

fn cleanup_old_sessions(project_log_dir: &Path) {
    let Ok(entries) = fs::read_dir(project_log_dir) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        if !name.to_string_lossy().starts_with(".wrapper_session_") {
            continue;
        }
        let stale = entry
            .metadata()
            .and_then(|meta| meta.modified())
            .ok()
            .and_then(|modified| modified.elapsed().ok())
            .is_some_and(|age| age > SESSION_CLEANUP_AGE);
        if stale {
            let _ = fs::remove_file(entry.path());
        }
    }
}

fn new_session_id(anchor: &SessionAnchor, project_root: &str) -> String {
    let mut hasher = DefaultHasher::new();
    anchor.pid.hash(&mut hasher);
    anchor.start.hash(&mut hasher);
    std::process::id().hash(&mut hasher);
    project_root.hash(&mut hasher);
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
        .hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

#[cfg(target_os = "linux")]
fn process_start_token(pid: libc::pid_t) -> Option<String> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    linux_stat_start_time(&stat)
}

#[cfg(target_os = "linux")]
fn linux_stat_start_time(stat: &str) -> Option<String> {
    let end = stat.rfind(") ")?;
    stat[end + 2..]
        .split_whitespace()
        .nth(19)
        .map(|value| value.to_string())
}

#[cfg(target_os = "macos")]
fn process_start_token(pid: libc::pid_t) -> Option<String> {
    use std::mem;

    let mut info = mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
    let size = mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    let result = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            info.as_mut_ptr().cast(),
            size,
        )
    };
    if result == size {
        let info = unsafe { info.assume_init() };
        Some(format!(
            "{}:{}",
            info.pbi_start_tvsec, info.pbi_start_tvusec
        ))
    } else {
        None
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn process_start_token(_pid: libc::pid_t) -> Option<String> {
    None
}

fn sanitize_token(value: &str) -> String {
    let token: String = value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.' | '-') {
                ch
            } else {
                '_'
            }
        })
        .collect();
    if token.is_empty() {
        "unknown".to_string()
    } else {
        token
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unique_temp_dir(name: &str) -> PathBuf {
        let mut path = env::temp_dir();
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        path.push(format!(
            "vibeguard-wrapper-env-{name}-{}-{nanos}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn project_root_walk_finds_git_marker_without_git_command() {
        let temp = unique_temp_dir("git-root");
        let repo = temp.join("repo");
        let nested = repo.join("a/b");
        fs::create_dir_all(repo.join(".git")).unwrap();
        fs::create_dir_all(&nested).unwrap();

        assert_eq!(project_root_for(&nested), fs::canonicalize(&repo).ok());
        let _ = fs::remove_dir_all(temp);
    }

    #[test]
    fn recent_session_is_reused() {
        let temp = unique_temp_dir("session");
        let session_file = temp.join(".wrapper_session_codex_1");
        fs::write(&session_file, "start-one\nsession-one\n").unwrap();

        assert_eq!(
            read_recent_session(&session_file, "start-one").as_deref(),
            Some("session-one")
        );
        let _ = fs::remove_dir_all(temp);
    }

    #[test]
    fn recent_session_rejects_mismatched_start_anchor() {
        let temp = unique_temp_dir("session-start");
        let session_file = temp.join(".wrapper_session_codex_1");
        fs::write(&session_file, "old-start\nsession-one\n").unwrap();

        assert_eq!(read_recent_session(&session_file, "new-start"), None);
        let _ = fs::remove_dir_all(temp);
    }

    #[test]
    fn legacy_single_line_session_is_reused() {
        let temp = unique_temp_dir("session-legacy");
        let session_file = temp.join(".wrapper_session_codex_1");
        fs::write(&session_file, "session-one").unwrap();

        assert_eq!(
            read_recent_session(&session_file, "ignored").as_deref(),
            Some("session-one")
        );
        let _ = fs::remove_dir_all(temp);
    }

    #[test]
    fn pid_parser_rejects_init_and_invalid_values() {
        assert_eq!(parse_pid("42"), Some(42));
        assert_eq!(parse_pid("1"), None);
        assert_eq!(parse_pid("nope"), None);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_stat_start_time_reads_field_22_after_comm() {
        let stat =
            "10 (bash with spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 12345 678";
        assert_eq!(linux_stat_start_time(stat).as_deref(), Some("12345"));
    }

    #[test]
    fn token_sanitizer_keeps_session_file_names_safe() {
        assert_eq!(sanitize_token("codex-cli"), "codex-cli");
        assert_eq!(sanitize_token("bad/value"), "bad_value");
        assert_eq!(sanitize_token(""), "unknown");
    }
}
