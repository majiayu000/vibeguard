use std::fs;
use std::path::{Path, PathBuf};

use crate::hook_checks_common::{absolute_parent, is_test_path};

#[derive(Debug, PartialEq, Eq)]
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_project(name: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "vg_helper_scan_{name}_{}_{}",
            std::process::id(),
            unique
        ));
        fs::create_dir_all(root.join(".git")).expect("temp git marker should be created");
        root
    }

    #[test]
    fn find_project_dir_walks_to_git_root() {
        let root = temp_project("find_project");
        let file_path = root.join("src").join("lib.rs");
        fs::create_dir_all(file_path.parent().expect("file should have parent"))
            .expect("src dir should be created");
        fs::write(&file_path, "fn main() {}\n").expect("file should be written");

        assert_eq!(
            find_project_dir(file_path.to_string_lossy().as_ref()),
            Some(root.clone())
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn scan_same_name_duplicate_flags_non_test_duplicate() {
        let root = temp_project("duplicate");
        let target = root.join("src").join("lib.rs");
        let duplicate = root.join("other").join("lib.rs");
        fs::create_dir_all(target.parent().expect("target should have parent"))
            .expect("target dir should be created");
        fs::create_dir_all(duplicate.parent().expect("duplicate should have parent"))
            .expect("duplicate dir should be created");
        fs::write(&target, "pub fn a() {}\n").expect("target should be written");
        fs::write(&duplicate, "pub fn b() {}\n").expect("duplicate should be written");

        assert_eq!(
            scan_same_name_duplicate(&root, target.to_string_lossy().as_ref(), 10),
            SameNameScan::Duplicate
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn scan_same_name_duplicate_ignores_test_dirs() {
        let root = temp_project("test_dir");
        let target = root.join("src").join("mod.rs");
        let duplicate = root.join("tests").join("mod.rs");
        fs::create_dir_all(target.parent().expect("target should have parent"))
            .expect("target dir should be created");
        fs::create_dir_all(duplicate.parent().expect("duplicate should have parent"))
            .expect("duplicate dir should be created");
        fs::write(&target, "pub fn a() {}\n").expect("target should be written");
        fs::write(&duplicate, "pub fn b() {}\n").expect("duplicate should be written");

        assert_eq!(
            scan_same_name_duplicate(&root, target.to_string_lossy().as_ref(), 10),
            SameNameScan::Clean
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn scan_same_name_duplicate_stops_when_too_large() {
        let root = temp_project("too_large");
        let target = root.join("src").join("main.rs");
        fs::create_dir_all(target.parent().expect("target should have parent"))
            .expect("target dir should be created");
        fs::write(&target, "fn main() {}\n").expect("target should be written");

        assert_eq!(
            scan_same_name_duplicate(&root, target.to_string_lossy().as_ref(), 0),
            SameNameScan::TooLarge
        );

        let _ = fs::remove_dir_all(root);
    }
}
