use std::collections::hash_map::DefaultHasher;
use std::fs;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::git_root::current_git_root_by_marker;
use crate::setup_support::sha256_text_short;
use crate::wrapper_env::{
    cleanup_old_sessions, env_nonempty, hash_slug_from_log_dir, log_root, read_recent_session,
    sanitize_token, write_session_file,
};

type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(Debug)]
pub(crate) struct RuntimeContext {
    pub(crate) log_root: PathBuf,
    pub(crate) log_file: PathBuf,
    pub(crate) project_hash: String,
    pub(crate) session_id: String,
    pub(crate) cli: String,
    pub(crate) client: String,
    pub(crate) client_variant: String,
    pub(crate) caller_evidence: String,
    pub(crate) session_source: String,
}

#[derive(Debug)]
struct ParentInfo {
    pid: i32,
    cli: String,
    start: String,
}

impl RuntimeContext {
    pub(crate) fn collect() -> Result<Self> {
        let log_root = log_root();
        let project_root = current_git_root_by_marker();
        let project_root_text = project_root
            .as_ref()
            .map(|path| path.to_string_lossy().to_string())
            .unwrap_or_else(|| "global".to_string());
        let computed_hash = sha256_text_short(&project_root_text);
        let explicit_project_log_dir = env_nonempty("VIBEGUARD_PROJECT_LOG_DIR").map(PathBuf::from);
        let explicit_log_file = env_nonempty("VIBEGUARD_LOG_FILE").map(PathBuf::from);
        let (project_hash, project_log_dir, log_file) =
            match (explicit_project_log_dir, explicit_log_file) {
                (Some(project_log_dir), Some(log_file)) => {
                    let project_hash = env_nonempty("VIBEGUARD_PROJECT_HASH")
                        .or_else(|| hash_slug_from_log_dir(&project_log_dir))
                        .unwrap_or_else(|| computed_hash.clone());
                    (project_hash, project_log_dir, log_file)
                }
                _ => {
                    let project_hash = computed_hash;
                    let project_log_dir = log_root.join("projects").join(&project_hash);
                    let log_file = project_log_dir.join("events.jsonl");
                    (project_hash, project_log_dir, log_file)
                }
            };

        fs::create_dir_all(&project_log_dir)?;
        if project_root.is_some() {
            let _ = fs::write(
                project_log_dir.join(".project-root"),
                project_root_text.as_bytes(),
            );
        }

        let explicit_cli = env_nonempty("VIBEGUARD_CLI");
        let explicit_session_id = env_nonempty("VIBEGUARD_SESSION_ID");
        let skip_parent_inference = explicit_cli.is_none() && explicit_session_id.is_some();
        let parent = if skip_parent_inference {
            None
        } else {
            infer_parent()
        };
        let cli = explicit_cli
            .or_else(|| parent.as_ref().map(|info| info.cli.clone()))
            .unwrap_or_else(|| "unknown".to_string());
        let session_id = explicit_session_id.unwrap_or_else(|| {
            resolve_session_id(&project_log_dir, &cli, &project_root_text, parent.as_ref())
        });
        let explicit_client = env_nonempty("VIBEGUARD_CLIENT");
        let client = explicit_client
            .clone()
            .unwrap_or_else(|| match cli.as_str() {
                "claude" => "claude".to_string(),
                "codex" => "codex".to_string(),
                _ => "unknown".to_string(),
            });
        let client_variant =
            env_nonempty("VIBEGUARD_CLIENT_VARIANT").unwrap_or_else(|| match client.as_str() {
                "claude" => "claude-code-hooks".to_string(),
                "codex" => "codex-cli-hooks".to_string(),
                _ => "unknown".to_string(),
            });
        let caller_evidence = env_nonempty("VIBEGUARD_CALLER_EVIDENCE").unwrap_or_else(|| {
            if explicit_client.is_some() {
                "explicit-client".to_string()
            } else if matches!(cli.as_str(), "claude" | "codex") {
                "parent-process".to_string()
            } else {
                "no-client-evidence".to_string()
            }
        });

        let session_source = env_nonempty("VIBEGUARD_SESSION_SOURCE").unwrap_or_default();

        Ok(Self {
            log_root,
            log_file,
            project_hash,
            session_id,
            cli,
            client,
            client_variant,
            caller_evidence,
            session_source,
        })
    }
}

fn resolve_session_id(
    project_log_dir: &Path,
    cli: &str,
    project_root: &str,
    parent: Option<&ParentInfo>,
) -> String {
    cleanup_old_sessions(project_log_dir);
    if let Some(parent) = parent {
        let token = sanitize_token(cli);
        let session_file = project_log_dir.join(format!(".session_{token}_{}", parent.pid));
        if let Some(session_id) = read_recent_session(&session_file, &parent.start) {
            let _ = write_session_file(&session_file, &parent.start, &session_id);
            return session_id;
        }
        let session_id = new_hook_session_id(parent.pid, &parent.start, project_root);
        let _ = write_session_file(&session_file, &parent.start, &session_id);
        return session_id;
    }

    let token = sanitize_token(cli);
    let session_file = project_log_dir.join(format!(".session_id_{token}"));
    if let Some(session_id) = read_recent_session(&session_file, "") {
        let _ = fs::write(&session_file, &session_id);
        return session_id;
    }
    let session_id = new_hook_session_id(0, "unknown", project_root);
    let _ = fs::write(&session_file, &session_id);
    session_id
}

fn new_hook_session_id(pid: i32, start: &str, project_root: &str) -> String {
    let mut hasher = DefaultHasher::new();
    pid.hash(&mut hasher);
    start.hash(&mut hasher);
    std::process::id().hash(&mut hasher);
    project_root.hash(&mut hasher);
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
        .hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

fn infer_parent() -> Option<ParentInfo> {
    let mut pid = env_nonempty("VIBEGUARD_WRAPPER_PARENT_PID")
        .and_then(|value| value.parse::<i32>().ok())
        .filter(|pid| *pid > 1)
        .unwrap_or_else(parent_pid);
    for _ in 0..8 {
        let ppid = ps_field(pid, "ppid")?.parse::<i32>().ok()?;
        if ppid <= 1 {
            return None;
        }
        let comm = ps_field(ppid, "comm").unwrap_or_default();
        if let Some(cli) = cli_from_process(&comm, None) {
            return Some(parent_info(ppid, cli));
        }
        if comm == "node" {
            let args = ps_field(ppid, "args").unwrap_or_default();
            if let Some(cli) = cli_from_process(&comm, Some(&args)) {
                return Some(parent_info(ppid, cli));
            }
        }
        pid = ppid;
    }
    None
}

#[cfg(unix)]
fn parent_pid() -> i32 {
    unsafe { libc::getppid() }
}

#[cfg(not(unix))]
fn parent_pid() -> i32 {
    0
}

fn parent_info(pid: i32, cli: &str) -> ParentInfo {
    ParentInfo {
        pid,
        cli: cli.to_string(),
        start: process_start_token(pid).unwrap_or_else(|| "unknown".to_string()),
    }
}

fn cli_from_process(comm: &str, args: Option<&str>) -> Option<&'static str> {
    let haystack = match args {
        Some(args) => format!("{comm} {args}").to_ascii_lowercase(),
        None => comm.to_ascii_lowercase(),
    };
    if haystack.contains("codex") {
        Some("codex")
    } else if haystack.contains("claude") || haystack.contains("electron") {
        Some("claude")
    } else {
        None
    }
}

fn ps_field(pid: i32, field_name: &str) -> Option<String> {
    let output = Command::new("ps")
        .args(["-o", &format!("{field_name}="), "-p", &pid.to_string()])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (!value.is_empty()).then_some(value)
}

fn process_start_token(pid: i32) -> Option<String> {
    let output = Command::new("ps")
        .env("TZ", "UTC")
        .args(["-o", "lstart=", "-p", &pid.to_string()])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (!value.is_empty()).then_some(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    #[test]
    fn explicit_session_file_reuses_recent_id() {
        let temp = env::temp_dir().join(format!(
            "vibeguard-hook-orchestrator-session-{}",
            std::process::id()
        ));
        fs::create_dir_all(&temp).unwrap();
        let file = temp.join(".session_id_codex");
        fs::write(&file, "session-one").unwrap();
        assert_eq!(
            read_recent_session(&file, "").as_deref(),
            Some("session-one")
        );
        let _ = fs::remove_dir_all(temp);
    }
}
