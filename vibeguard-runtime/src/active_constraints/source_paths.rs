use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

pub(super) fn codex_project_instruction_files(root: &Path, task_paths: &[String]) -> Vec<PathBuf> {
    let resolved_root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    let mut instruction_files = BTreeSet::new();
    add_instruction_file(&mut instruction_files, &resolved_root);
    for task_path in task_paths {
        let candidate = PathBuf::from(task_path);
        let candidate = if candidate.is_absolute() {
            candidate
        } else {
            resolved_root.join(candidate)
        };
        let Some(candidate) = resolve_nearest_existing(&candidate) else {
            continue;
        };
        if !candidate.starts_with(&resolved_root) {
            continue;
        }
        let mut directory = if candidate.is_dir() {
            candidate
        } else {
            candidate.parent().unwrap_or(&resolved_root).to_path_buf()
        };
        while directory != resolved_root {
            add_instruction_file(&mut instruction_files, &directory);
            if !directory.pop() {
                break;
            }
        }
    }
    instruction_files.into_iter().collect()
}

fn add_instruction_file(instruction_files: &mut BTreeSet<PathBuf>, directory: &Path) {
    let override_path = directory.join("AGENTS.override.md");
    instruction_files.insert(if override_path.is_file() {
        override_path
    } else {
        directory.join("AGENTS.md")
    });
}

fn resolve_nearest_existing(candidate: &Path) -> Option<PathBuf> {
    let mut ancestor = candidate;
    let mut suffix = Vec::new();
    while !ancestor.exists() {
        suffix.push(ancestor.file_name()?.to_os_string());
        ancestor = ancestor.parent()?;
    }
    let mut resolved = ancestor.canonicalize().ok()?;
    for component in suffix.into_iter().rev() {
        resolved.push(component);
    }
    Some(resolved)
}
