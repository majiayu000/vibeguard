use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

pub(crate) fn current_git_root() -> Option<PathBuf> {
    let output = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()?;
    parse_git_root_output(output)
}

pub(crate) fn git_root_for(cwd: &Path) -> Option<PathBuf> {
    let output = Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()?;
    parse_git_root_output(output)
}

pub(crate) fn current_git_root_by_marker() -> Option<PathBuf> {
    git_root_by_marker_for(&std::env::current_dir().ok()?)
}

pub(crate) fn git_root_by_marker_for(cwd: &Path) -> Option<PathBuf> {
    let mut current = cwd.to_path_buf();
    loop {
        if current.join(".git").exists() {
            return fs::canonicalize(&current).ok().or(Some(current));
        }
        if !current.pop() {
            return None;
        }
    }
}

fn parse_git_root_output(output: Output) -> Option<PathBuf> {
    if !output.status.success() {
        return None;
    }
    let root = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if root.is_empty() {
        None
    } else {
        Some(PathBuf::from(root))
    }
}
