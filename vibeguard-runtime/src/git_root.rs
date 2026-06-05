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
