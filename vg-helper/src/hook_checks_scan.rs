use std::fs;
use std::path::{Path, PathBuf};

use crate::hook_checks_common::{absolute_parent, is_test_path};

pub(crate) enum SameNameScan {
    Clean,
    Duplicate,
    TooLarge,
}

pub(crate) fn find_project_dir(file_path: &str) -> Option<PathBuf> {
    let mut dir = absolute_parent(file_path)?;
    loop {
        if dir.join(".git").exists() {
            return Some(dir);
        }
        let parent = dir.parent()?.to_path_buf();
        if parent == dir {
            return None;
        }
        dir = parent;
    }
}

pub(crate) fn scan_same_name_duplicate(
    project_dir: &Path,
    file_path: &str,
    max_files: usize,
) -> SameNameScan {
    let Some(basename) = Path::new(file_path).file_name().and_then(|s| s.to_str()) else {
        return SameNameScan::Clean;
    };
    let target_abs = absolute_path(file_path);
    let mut file_count = 0usize;
    scan_same_name_dir(
        project_dir,
        basename,
        &target_abs,
        max_files,
        &mut file_count,
    )
}

fn scan_same_name_dir(
    dir: &Path,
    basename: &str,
    target_abs: &Path,
    max_files: usize,
    file_count: &mut usize,
) -> SameNameScan {
    let Ok(entries) = fs::read_dir(dir) else {
        return SameNameScan::Clean;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() {
            if should_skip_scan_dir(&path) {
                continue;
            }
            match scan_same_name_dir(&path, basename, target_abs, max_files, file_count) {
                SameNameScan::Clean => {}
                other => return other,
            }
        } else if file_type.is_file() {
            *file_count += 1;
            if *file_count > max_files {
                return SameNameScan::TooLarge;
            }
            if path.file_name().and_then(|s| s.to_str()) == Some(basename)
                && absolute_path(path.to_string_lossy().as_ref()) != target_abs
                && !is_test_path(path.to_string_lossy().as_ref())
            {
                return SameNameScan::Duplicate;
            }
        }
    }
    SameNameScan::Clean
}

fn should_skip_scan_dir(path: &Path) -> bool {
    matches!(
        path.file_name().and_then(|s| s.to_str()),
        Some(
            "node_modules"
                | ".git"
                | "target"
                | "vendor"
                | "dist"
                | "build"
                | "__pycache__"
                | ".venv"
                | "tests"
                | "__tests__"
                | "test"
                | "spec"
        )
    )
}

fn absolute_path(path: &str) -> PathBuf {
    let path = Path::new(path);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    }
}
