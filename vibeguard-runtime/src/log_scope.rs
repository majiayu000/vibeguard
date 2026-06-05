use std::env;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::git_root::{current_git_root, git_root_for};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum LogScope {
    Project,
    Global,
}

#[derive(Debug)]
pub(crate) struct LogScopeOptions {
    pub(crate) scope: LogScope,
    pub(crate) project: Option<String>,
    pub(crate) log_file: Option<PathBuf>,
    pub(crate) allow_env_log_file: bool,
}

#[derive(Debug, Eq, PartialEq)]
pub(crate) struct ResolvedLogFile {
    pub(crate) path: PathBuf,
}

pub(crate) fn parse_scope(value: &str) -> Result<LogScope> {
    match value {
        "project" => Ok(LogScope::Project),
        "global" => Ok(LogScope::Global),
        _ => Err("scope must be one of: project, global".into()),
    }
}

pub(crate) fn resolve_log_file(options: &LogScopeOptions) -> Result<ResolvedLogFile> {
    if let Some(path) = &options.log_file {
        return Ok(ResolvedLogFile { path: path.clone() });
    }

    if options.allow_env_log_file {
        if let Ok(path) = env::var("VIBEGUARD_LOG_FILE") {
            if !path.trim().is_empty() {
                return Ok(ResolvedLogFile {
                    path: PathBuf::from(path),
                });
            }
        }
    }

    let log_root = log_root();
    match options.scope {
        LogScope::Global => Ok(ResolvedLogFile {
            path: log_root.join("events.jsonl"),
        }),
        LogScope::Project => {
            let project = match &options.project {
                Some(value) => ProjectRef::from_user_value(value),
                None => match current_git_root() {
                    Some(root) => ProjectRef::Path(root),
                    None => {
                        return Ok(ResolvedLogFile {
                            path: log_root.join("events.jsonl"),
                        });
                    }
                },
            };
            Ok(ResolvedLogFile {
                path: project_log_path(&log_root, project)?,
            })
        }
    }
}

fn log_root() -> PathBuf {
    env::var("VIBEGUARD_LOG_DIR")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            env::var("HOME")
                .ok()
                .map(|home| PathBuf::from(home).join(".vibeguard"))
        })
        .unwrap_or_else(|| PathBuf::from(".vibeguard"))
}

enum ProjectRef {
    Hash(String),
    Path(PathBuf),
}

impl ProjectRef {
    fn from_user_value(value: &str) -> Self {
        if looks_like_project_hash(value) {
            Self::Hash(value.to_ascii_lowercase())
        } else {
            Self::Path(resolve_project_root(Path::new(value)))
        }
    }
}

fn looks_like_project_hash(value: &str) -> bool {
    let len = value.len();
    (8..=64).contains(&len)
        && !value.contains('/')
        && !value.contains('\\')
        && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn project_log_path(log_root: &Path, project: ProjectRef) -> Result<PathBuf> {
    match project {
        ProjectRef::Hash(hash) => Ok(log_root
            .join("projects")
            .join(&hash[..8])
            .join("events.jsonl")),
        ProjectRef::Path(root) => {
            let root_text = root.to_string_lossy().to_string();
            if let Some(path) = project_log_path_from_mapping(log_root, &root_text) {
                return Ok(path);
            }
            let digest = sha256_short(&root_text)?;
            Ok(log_root.join("projects").join(digest).join("events.jsonl"))
        }
    }
}

fn resolve_project_root(path: &Path) -> PathBuf {
    git_root_for(path).unwrap_or_else(|| path.to_path_buf())
}

fn project_log_path_from_mapping(log_root: &Path, root_text: &str) -> Option<PathBuf> {
    let projects_dir = log_root.join("projects");
    let entries = fs::read_dir(projects_dir).ok()?;
    for entry in entries.flatten() {
        let mapping = entry.path().join(".project-root");
        let Ok(mapped_root) = fs::read_to_string(&mapping) else {
            continue;
        };
        if same_project_root(mapped_root.trim(), root_text) {
            return Some(entry.path().join("events.jsonl"));
        }
    }
    None
}

fn same_project_root(left: &str, right: &str) -> bool {
    if left == right {
        return true;
    }
    let left_path = Path::new(left);
    let right_path = Path::new(right);
    match (fs::canonicalize(left_path), fs::canonicalize(right_path)) {
        (Ok(left_real), Ok(right_real)) => left_real == right_real,
        _ => false,
    }
}

fn sha256_short(input: &str) -> Result<String> {
    for (program, args) in [("shasum", &["-a", "256"][..]), ("sha256sum", &[][..])] {
        if let Some(digest) = run_sha256_command(program, args, input)? {
            return Ok(digest);
        }
    }
    Err("unable to compute project log hash: shasum or sha256sum is required".into())
}

fn run_sha256_command(program: &str, args: &[&str], input: &str) -> Result<Option<String>> {
    let mut child = match Command::new(program)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(child) => child,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(Box::new(error)),
    };

    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(input.as_bytes())?;
    }
    let output = child.wait_with_output()?;
    if !output.status.success() {
        return Ok(None);
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let digest = text
        .split_whitespace()
        .next()
        .filter(|value| value.len() >= 8 && value.bytes().all(|byte| byte.is_ascii_hexdigit()));
    Ok(digest.map(|value| value[..8].to_ascii_lowercase()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn hash_ref_resolves_project_log_directly() {
        let root = PathBuf::from("/tmp/vg-logs");
        let path = project_log_path(&root, ProjectRef::Hash("abcdef123456".to_string())).unwrap();
        assert_eq!(
            path,
            PathBuf::from("/tmp/vg-logs/projects/abcdef12/events.jsonl")
        );
    }

    #[test]
    fn mapping_wins_for_project_path() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let temp = env::temp_dir().join(format!("vibeguard-log-scope-{unique}"));
        let project = temp.join("repo");
        let mapped = temp.join("logs/projects/knownhash");
        fs::create_dir_all(&project).unwrap();
        fs::create_dir_all(&mapped).unwrap();
        fs::write(
            mapped.join(".project-root"),
            project.to_string_lossy().as_ref(),
        )
        .unwrap();

        let path = project_log_path(&temp.join("logs"), ProjectRef::Path(project)).unwrap();
        assert_eq!(path, mapped.join("events.jsonl"));

        let _ = fs::remove_dir_all(temp);
    }
}
