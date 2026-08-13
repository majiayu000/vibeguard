use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

pub(super) fn codex_project_instruction_files(root: &Path, task_paths: &[String]) -> Vec<PathBuf> {
    let resolved_root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    let mut instruction_files = BTreeSet::new();
    for task_path in task_paths {
        let candidate = PathBuf::from(task_path);
        let candidate = if candidate.is_absolute() {
            candidate
        } else {
            resolved_root.join(candidate)
        };
        let candidate = candidate.canonicalize().unwrap_or(candidate);
        if !candidate.starts_with(&resolved_root) {
            continue;
        }
        let mut directory = if candidate.is_dir() {
            candidate
        } else {
            candidate.parent().unwrap_or(&resolved_root).to_path_buf()
        };
        while directory != resolved_root {
            instruction_files.insert(directory.join("AGENTS.md"));
            if !directory.pop() {
                break;
            }
        }
    }
    instruction_files.into_iter().collect()
}
