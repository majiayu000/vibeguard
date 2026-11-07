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
    if !is_page(path)
        || !destinations(path, cwd)
            .iter()
            .any(|dest| is_temporary(dest, temp_dir))
    {
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

/// Where the file could land. `link/../x` has two answers: Claude's Write collapses `..`
/// first (measured), the operating system follows `link` first. Either being temporary
/// refuses the write, so the check doesn't depend on which one a tool uses.
fn destinations(path: &str, cwd: &str) -> [PathBuf; 2] {
    let path = Path::new(cwd).join(path);
    [real_path(&normalize(&path)), real_path(&path)]
}

/// Follows symlinks through the deepest ancestor that exists, because Write creates the
/// missing directories below it; what remains is collapsed by its spelling.
fn real_path(path: &Path) -> PathBuf {
    let existing = path
        .parent()
        .into_iter()
        .flat_map(Path::ancestors)
        .find_map(|dir| Some((dir, dir.canonicalize().ok()?)));
    match existing {
        Some((dir, real)) => normalize(&real.join(path.strip_prefix(dir).unwrap_or(path))),
        None => normalize(path),
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

    #[cfg(unix)]
    #[test]
    fn a_symlink_then_parent_counts_where_it_leads_and_where_it_is_spelled() {
        let id = std::process::id();
        let root = std::env::current_dir()
            .unwrap()
            .join(format!("target/temp-page-dotdot-{id}"));
        let temp = PathBuf::from(format!("/tmp/vibeguard-temp-page-test-{id}"));
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&temp);
        std::fs::create_dir_all(root.join("pages")).unwrap();
        std::fs::create_dir_all(root.join("kept/child")).unwrap();
        std::fs::create_dir_all(temp.join("child")).unwrap();
        std::os::unix::fs::symlink(temp.join("child"), root.join("pages/to-temp")).unwrap();
        std::os::unix::fs::symlink(root.join("kept/child"), root.join("pages/to-kept")).unwrap();
        let in_pages =
            |path: &str| blocked(root.join("pages").join(path).to_str().unwrap(), "/repo");
        assert!(in_pages("to-temp/../x.html"));
        assert!(!in_pages("to-kept/../x.html"));
        assert!(in_pages("to-temp/new/dir/x.html"));
        assert!(!in_pages("to-kept/new/dir/x.html"));
        std::fs::remove_dir_all(&root).unwrap();
        std::fs::remove_dir_all(&temp).unwrap();
    }

    #[test]
    fn a_parent_that_does_not_exist_yet_is_still_temporary() {
        assert!(blocked("/tmp/vibeguard-absent/new/dir/x.html", "/repo"));
        assert!(!blocked("/nowhere/new/dir/x.html", "/repo"));
    }

    #[test]
    fn the_switch_is_off_unless_set_and_rejects_typos() {
        assert_eq!(enabled(None), Ok(false));
        assert_eq!(enabled(Some("")), Ok(false));
        assert_eq!(enabled(Some("deny")), Ok(true));
        assert!(enabled(Some("yes")).is_err());
    }
}
