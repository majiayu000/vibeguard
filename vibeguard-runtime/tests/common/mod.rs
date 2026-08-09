#![allow(dead_code)]

use serde_json::Value;
use std::fs;
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

pub fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"))
}

pub fn unique_temp_dir(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "vibeguard-runtime-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

pub fn run_with_home(root: &Path, args: &[&str]) -> Output {
    bin()
        .args(args)
        .env("HOME", root.join("home"))
        .current_dir(root)
        .output()
        .expect("vibeguard-runtime command should run")
}

pub fn assert_output(output: &Output, code: i32, stdout: &str, stderr: &str) {
    assert_eq!(output.status.code(), Some(code));
    assert_eq!(String::from_utf8_lossy(&output.stdout), stdout);
    assert_eq!(String::from_utf8_lossy(&output.stderr), stderr);
}

pub fn write_json(path: &Path, value: &Value) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("JSON parent should be created");
    }
    fs::write(
        path,
        format!(
            "{}\n",
            serde_json::to_string_pretty(value).expect("fixture should serialize")
        ),
    )
    .expect("JSON fixture should be written");
}

pub fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).expect("state file should be readable"))
        .expect("state file should contain JSON")
}

pub fn path_text(path: &Path) -> String {
    path.to_str()
        .expect("temporary paths should be UTF-8")
        .to_string()
}

#[cfg(unix)]
pub fn file_mode(path: &std::path::Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

pub fn run_runtime_with_stdin(args: &[&str], input: &str) -> std::process::Output {
    let mut child = bin()
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}
