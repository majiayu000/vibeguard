//! Source files may not grow past `MAX_LINES`. A file already above the limit
//! may still be edited as long as the edit does not make it longer, so an
//! existing large file can be split or trimmed but never extended.

use serde_json::Value;
use std::path::Path;

pub const MAX_LINES: usize = 800;

const SOURCE_EXTENSIONS: &[&str] = &[
    "rs", "py", "ts", "tsx", "js", "jsx", "mjs", "cjs", "go", "java", "kt", "kts", "swift", "c",
    "h", "cc", "cpp", "hpp", "m", "mm", "cs", "rb", "php", "scala", "lua", "dart", "vue", "svelte",
    "zig", "ex", "exs", "sh", "bash", "zsh",
];

pub fn is_edit_tool(tool: &str) -> bool {
    matches!(tool, "Write" | "Edit" | "MultiEdit")
}

/// Returns a denial reason when the proposed edit would leave a source file
/// above the limit and longer than it is now. Edits whose result cannot be
/// predicted (missing file, unmatched text) are left to the host tool, which
/// reports its own error.
pub fn blocked_reason(tool: &str, input: &Value) -> Option<String> {
    let path = input.get("file_path")?.as_str()?;
    if !is_source(path) {
        return None;
    }
    let current = std::fs::read_to_string(path).ok();
    let proposed = match tool {
        "Write" => input.get("content")?.as_str()?.to_string(),
        "Edit" => apply(current.as_deref()?, input)?,
        "MultiEdit" => input
            .get("edits")?
            .as_array()?
            .iter()
            .try_fold(current.clone()?, |text, edit| apply(&text, edit))?,
        _ => return None,
    };
    let after = count_lines(&proposed);
    let before = current.as_deref().map_or(0, count_lines);
    if after <= MAX_LINES || after <= before {
        return None;
    }
    Some(if before > MAX_LINES {
        format!(
            "{path} already has {before} lines, above the {MAX_LINES}-line limit; this edit would grow it to {after}. Move code out by responsibility instead of adding to this file."
        )
    } else {
        format!(
            "{path} would have {after} lines, above the {MAX_LINES}-line limit. Split it by responsibility into separate files."
        )
    })
}

pub(super) fn is_source(path: &str) -> bool {
    Path::new(path)
        .extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| SOURCE_EXTENSIONS.contains(&ext.to_ascii_lowercase().as_str()))
}

fn apply(text: &str, edit: &Value) -> Option<String> {
    let old = edit.get("old_string")?.as_str()?;
    let new = edit.get("new_string")?.as_str()?;
    if old.is_empty() || !text.contains(old) {
        return None;
    }
    if edit.get("replace_all").and_then(Value::as_bool) == Some(true) {
        Some(text.replace(old, new))
    } else {
        Some(text.replacen(old, new, 1))
    }
}

pub(super) fn count_lines(text: &str) -> usize {
    text.lines().count()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn lines(n: usize) -> String {
        "x\n".repeat(n)
    }

    fn file(n: usize) -> (tempfile_dir::Dir, String) {
        let dir = tempfile_dir::Dir::new();
        let path = dir.path.join("a.rs");
        std::fs::write(&path, lines(n)).unwrap();
        let path = path.to_str().unwrap().to_string();
        (dir, path)
    }

    #[test]
    fn new_file_above_limit_is_blocked() {
        let input = json!({"file_path":"/nowhere/new.rs","content":lines(801)});
        assert!(blocked_reason("Write", &input).is_some());
        let input = json!({"file_path":"/nowhere/new.rs","content":lines(800)});
        assert!(blocked_reason("Write", &input).is_none());
    }

    #[test]
    fn non_source_files_are_ignored() {
        for name in [
            "/nowhere/a.md",
            "/nowhere/a.json",
            "/nowhere/a.html",
            "/nowhere/Makefile",
        ] {
            let input = json!({"file_path":name,"content":lines(5000)});
            assert!(blocked_reason("Write", &input).is_none(), "{name}");
        }
    }

    #[test]
    fn edit_crossing_the_limit_is_blocked() {
        let (_dir, path) = file(800);
        let grow = json!({"file_path":path,"old_string":"x\n","new_string":"x\ny\n"});
        assert!(blocked_reason("Edit", &grow).unwrap().contains("801 lines"));
        let same = json!({"file_path":path,"old_string":"x\n","new_string":"z\n"});
        assert!(blocked_reason("Edit", &same).is_none());
    }

    #[test]
    fn oversized_file_may_shrink_or_stay_but_not_grow() {
        let (_dir, path) = file(1000);
        let grow = json!({"file_path":path,"old_string":"x\n","new_string":"x\ny\n"});
        assert!(
            blocked_reason("Edit", &grow)
                .unwrap()
                .contains("already has 1000")
        );
        let shrink = json!({"file_path":path,"old_string":"x\nx\n","new_string":"x\n"});
        assert!(blocked_reason("Edit", &shrink).is_none());
        let rewrite = json!({"file_path":path,"content":lines(1000)});
        assert!(blocked_reason("Write", &rewrite).is_none());
        let rewrite = json!({"file_path":path,"content":lines(1001)});
        assert!(blocked_reason("Write", &rewrite).is_some());
    }

    #[test]
    fn replace_all_and_multi_edit_count_every_change() {
        let (_dir, path) = file(500);
        let all =
            json!({"file_path":path,"old_string":"x\n","new_string":"x\nx\n","replace_all":true});
        assert!(blocked_reason("Edit", &all).is_some());
        let one = json!({"file_path":path,"old_string":"x\n","new_string":"x\nx\n"});
        assert!(blocked_reason("Edit", &one).is_none());
        let edit = json!({"old_string":"x\n","new_string":&lines(200)});
        let multi = json!({"file_path":path,"edits":[edit, edit]});
        assert!(
            blocked_reason("MultiEdit", &multi)
                .unwrap()
                .contains("898 lines")
        );
    }

    #[test]
    fn unpredictable_edits_are_left_to_the_host() {
        let missing =
            json!({"file_path":"/nowhere/a.rs","old_string":"x","new_string":&lines(900)});
        assert!(blocked_reason("Edit", &missing).is_none());
        let (_dir, path) = file(10);
        let unmatched = json!({"file_path":path,"old_string":"nope","new_string":&lines(900)});
        assert!(blocked_reason("Edit", &unmatched).is_none());
    }

    mod tempfile_dir {
        use std::path::PathBuf;
        use std::sync::atomic::{AtomicUsize, Ordering};

        pub struct Dir {
            pub path: PathBuf,
        }

        impl Dir {
            pub fn new() -> Self {
                static NEXT: AtomicUsize = AtomicUsize::new(0);
                let path = std::env::temp_dir().join(format!(
                    "vibeguard-file-size-{}-{}",
                    std::process::id(),
                    NEXT.fetch_add(1, Ordering::Relaxed)
                ));
                std::fs::create_dir_all(&path).unwrap();
                Dir { path }
            }
        }

        impl Drop for Dir {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.path);
            }
        }
    }
}
