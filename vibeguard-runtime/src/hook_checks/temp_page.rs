//! Opt-in: `VIBEGUARD_TEMP_PAGES=deny` refuses a `Write` of an HTML page under a
//! temporary directory, where the system deletes it later. Off by default because
//! writing HTML there is not destructive and is often right, as with test fixtures.

use serde_json::Value;
use std::path::{Component, Path, PathBuf};

pub const SWITCH: &str = "VIBEGUARD_TEMP_PAGES";

const TEMP_ROOTS: &[&str] = &[
    "/tmp",
    "/var/tmp",
    "/var/folders",
    "/private/tmp",
    "/private/var/tmp",
    "/private/var/folders",
];

/// Whether the check is on. Any other value is an error rather than silently off, so a
/// typo cannot leave someone believing they are protected.
pub fn enabled(value: Option<&str>) -> Result<bool, String> {
    match value {
        None | Some("") => Ok(false),
        Some("deny") => Ok(true),
        Some(other) => Err(format!("{SWITCH} must be \"deny\" or unset, not {other:?}")),
    }
}

pub fn blocked_reason(tool: &str, input: &Value, cwd: &str, temp_dir: &Path) -> Option<String> {
    if tool != "Write" {
        return None;
    }
    let path = input.get("file_path")?.as_str()?;
    if !is_page(path) || !is_temporary(&resolve(path, cwd), temp_dir) {
        return None;
    }
    Some(format!(
        "{path} is an HTML page in a temporary directory, which the system deletes later. Save it in a directory that is kept, with the files it references."
    ))
}

fn is_page(path: &str) -> bool {
    Path::new(path)
        .extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("html") || ext.eq_ignore_ascii_case("htm"))
}

/// The absolute path the file would have: `..` collapsed, and the parent's symlinks
/// followed when the parent exists yet.
fn resolve(path: &str, cwd: &str) -> PathBuf {
    let path = normalize(&Path::new(cwd).join(path));
    let real_parent = path.parent().and_then(|p| p.canonicalize().ok());
    match (real_parent, path.file_name()) {
        (Some(parent), Some(name)) => parent.join(name),
        _ => path,
    }
}

fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out
}

fn is_temporary(path: &Path, temp_dir: &Path) -> bool {
    let real_temp = temp_dir.canonicalize().ok();
    TEMP_ROOTS.iter().any(|root| path.starts_with(root))
        || path.starts_with(normalize(temp_dir))
        || real_temp.is_some_and(|dir| path.starts_with(dir))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn blocked(path: &str, cwd: &str) -> bool {
        let input = json!({"file_path": path, "content": "<!doctype html>"});
        blocked_reason("Write", &input, cwd, Path::new("/custom/tmp")).is_some()
    }

    #[test]
    fn pages_in_temporary_directories_are_refused() {
        for path in [
            "/tmp/demo.html",
            "/private/tmp/a/b/PAGE.HTM",
            "/var/folders/ab/T/x.html",
            "/custom/tmp/x.html",
            "/home/me/../../tmp/x.html",
        ] {
            assert!(blocked(path, "/repo"), "{path}");
        }
        assert!(blocked("x.html", "/tmp/work"));
        assert!(blocked("../x.html", "/tmp/work"));
    }

    #[test]
    fn everything_else_is_left_alone() {
        for path in [
            "/nowhere/pages/demo.html",
            "/tmp/notes.md",
            "/tmp/html",
            "/tmpfoo/x.html",
            "/tmp/../nowhere/x.html",
        ] {
            assert!(!blocked(path, "/repo"), "{path}");
        }
        assert!(!blocked("x.html", "/repo"));
        assert!(!blocked("../x.html", "/tmp"));
    }

    #[test]
    fn only_write_makes_a_page() {
        let input = json!({"file_path": "/tmp/x.html", "old_string": "a", "new_string": "b"});
        for tool in ["Edit", "MultiEdit"] {
            assert_eq!(
                blocked_reason(tool, &input, "/repo", Path::new("/custom/tmp")),
                None
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_parent_is_followed() {
        let root = std::env::current_dir()
            .unwrap()
            .join("target/temp-page-test");
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let kept = root.join("kept");
        std::fs::create_dir(&kept).unwrap();
        let to_temp = root.join("to-temp");
        std::os::unix::fs::symlink("/tmp", &to_temp).unwrap();
        let to_kept = root.join("to-kept");
        std::os::unix::fs::symlink(&kept, &to_kept).unwrap();
        assert!(blocked(to_temp.join("x.html").to_str().unwrap(), "/repo"));
        assert!(!blocked(to_kept.join("x.html").to_str().unwrap(), "/repo"));
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn the_switch_is_off_unless_set_and_rejects_typos() {
        assert_eq!(enabled(None), Ok(false));
        assert_eq!(enabled(Some("")), Ok(false));
        assert_eq!(enabled(Some("deny")), Ok(true));
        assert!(enabled(Some("yes")).is_err());
    }
}
