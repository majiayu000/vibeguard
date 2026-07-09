use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use crate::git_root::{current_git_root, git_root_for};
use crate::setup_support::sha256_text_short;

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

    if options.allow_env_log_file
        && let Ok(path) = env::var("VIBEGUARD_LOG_FILE")
        && !path.trim().is_empty()
    {
        return Ok(ResolvedLogFile {
            path: PathBuf::from(path),
        });
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
            let digest = sha256_text_short(&root_text);
            let direct_path = log_root.join("projects").join(digest).join("events.jsonl");
            if direct_path.exists() {
                return Ok(direct_path);
            }
            if let Some(path) = project_log_path_from_mapping(log_root, &root_text) {
                return Ok(path);
            }
            Ok(direct_path)
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

    #[test]
    fn deterministic_hash_path_wins_before_legacy_mapping_scan() {
        let unique = match SystemTime::now().duration_since(UNIX_EPOCH) {
            Ok(duration) => duration.as_nanos(),
            Err(error) => panic!("system time should be after unix epoch: {error}"),
        };
        let temp = env::temp_dir().join(format!("vibeguard-log-scope-direct-{unique}"));
        let project = temp.join("repo");
        let log_root = temp.join("logs");
        let direct = log_root
            .join("projects")
            .join(sha256_text_short(project.to_string_lossy().as_ref()));
        let mapped = log_root.join("projects/knownhash");
        if let Err(error) = fs::create_dir_all(&project) {
            panic!("test project directory should be created: {error}");
        }
        if let Err(error) = fs::create_dir_all(&direct) {
            panic!("direct log directory should be created: {error}");
        }
        if let Err(error) = fs::create_dir_all(&mapped) {
            panic!("legacy mapped directory should be created: {error}");
        }
        if let Err(error) = fs::write(direct.join("events.jsonl"), "") {
            panic!("direct log file should be created: {error}");
        }
        if let Err(error) = fs::write(
            mapped.join(".project-root"),
            project.to_string_lossy().as_ref(),
        ) {
            panic!("legacy mapping should be written: {error}");
        }

        let path = match project_log_path(&log_root, ProjectRef::Path(project)) {
            Ok(path) => path,
            Err(error) => panic!("project log path should resolve: {error}"),
        };
        assert_eq!(path, direct.join("events.jsonl"));

        if let Err(error) = fs::remove_dir_all(temp) {
            panic!("test temp directory should be removed: {error}");
        }
    }
}
