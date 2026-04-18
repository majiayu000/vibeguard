//! Package manager transparent correction: npm/yarn→pnpm, pip→uv.
//! Replaces hooks/_lib/pkg_rewrite.py.

use regex::Regex;
use std::io::{self, Read};

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

/// Reads a shell command from stdin, prints corrected command or empty string.
pub fn run(_args: &[String]) -> Result {
    let mut cmd = String::new();
    io::stdin().read_to_string(&mut cmd)?;
    let cmd = cmd.trim();

    // Skip complex commands (&&, ||, ;, pipe, redirection, $(), backtick)
    let complex = Regex::new(r"&&|&|\|\||;|[|<>\n\r]|\$\(|`")?;
    if complex.is_match(cmd) {
        println!();
        return Ok(());
    }

    let corrected = try_npm(cmd)
        .or_else(|| try_yarn(cmd))
        .or_else(|| try_pip(cmd))
        .or_else(|| try_python_pip(cmd));

    println!("{}", corrected.unwrap_or_default());
    Ok(())
}

fn try_npm(cmd: &str) -> Option<String> {
    let bare_install = Regex::new(r"^npm\s+(?:install|i)\s*$").ok()?;
    if bare_install.is_match(cmd) {
        return Some("pnpm install".into());
    }

    let pkg_install = Regex::new(r"^npm\s+(?:install|i|add)\s+").ok()?;
    if !pkg_install.is_match(cmd) {
        return None;
    }
    let rest = pkg_install.replace(cmd, "").trim().to_string();
    let tokens: Vec<&str> = rest.split_whitespace().collect();

    const KNOWN: &[&str] = &[
        "--save-dev",
        "-D",
        "--save",
        "-S",
        "--save-optional",
        "-O",
        "--save-exact",
        "-E",
    ];
    if tokens
        .iter()
        .any(|t| *t == "-g" || *t == "--global" || t.starts_with("--location=global"))
    {
        return None;
    }
    if tokens
        .iter()
        .any(|t| t.starts_with('-') && !KNOWN.contains(t))
    {
        return None;
    }
    let packages: Vec<&str> = tokens
        .iter()
        .filter(|t| !t.starts_with('-'))
        .copied()
        .collect();
    if packages.is_empty() {
        return None;
    }

    let mut flags = Vec::new();
    for t in &tokens {
        match *t {
            "--save-dev" | "-D" => flags.push("-D"),
            "--save-optional" | "-O" => flags.push("-O"),
            "--save-exact" | "-E" => flags.push("--save-exact"),
            _ => {}
        }
    }
    flags.extend(packages);
    Some(format!("pnpm add {}", flags.join(" ")))
}

fn try_yarn(cmd: &str) -> Option<String> {
    let bare = Regex::new(r"^yarn\s+install\s*$").ok()?;
    if bare.is_match(cmd) {
        return Some("pnpm install".into());
    }

    let add = Regex::new(r"^yarn\s+add\s+").ok()?;
    if !add.is_match(cmd) {
        return None;
    }
    let rest = add.replace(cmd, "").to_string();
    let tokens: Vec<&str> = rest.split_whitespace().collect();

    const KNOWN: &[&str] = &[
        "-D",
        "--dev",
        "--save-dev",
        "-O",
        "--optional",
        "-E",
        "--exact",
        "-P",
        "--save-peer",
        "-W",
        "--ignore-workspace-root-check",
    ];
    if tokens
        .iter()
        .any(|t| t.starts_with('-') && !KNOWN.contains(t))
    {
        return None;
    }
    let packages: Vec<&str> = tokens
        .iter()
        .filter(|t| !t.starts_with('-'))
        .copied()
        .collect();
    if packages.is_empty() {
        return None;
    }

    let mut flags = Vec::new();
    for t in &tokens {
        match *t {
            "-D" | "--dev" | "--save-dev" => flags.push("-D"),
            "-O" | "--optional" => flags.push("-O"),
            "-E" | "--exact" => flags.push("--save-exact"),
            "-P" | "--save-peer" => flags.push("--save-peer"),
            "-W" | "--ignore-workspace-root-check" => flags.push("-w"),
            _ => {}
        }
    }
    flags.extend(packages);
    Some(format!("pnpm add {}", flags.join(" ")))
}

fn try_pip(cmd: &str) -> Option<String> {
    let re = Regex::new(r"^pip3?\s+install\s+").ok()?;
    if !re.is_match(cmd) {
        return None;
    }
    let rest = re.replace(cmd, "").to_string();
    check_pip_flags(&rest).map(|_| format!("uv pip install {rest}"))
}

fn try_python_pip(cmd: &str) -> Option<String> {
    let re = Regex::new(r"^python3?\s+-m\s+pip\s+install\s+").ok()?;
    if !re.is_match(cmd) {
        return None;
    }
    let rest = re.replace(cmd, "").to_string();
    check_pip_flags(&rest).map(|_| format!("uv pip install {rest}"))
}

fn check_pip_flags(rest: &str) -> Option<()> {
    const KNOWN: &[&str] = &[
        "-r",
        "--requirement",
        "-e",
        "--editable",
        "-U",
        "--upgrade",
        "--pre",
        "--no-deps",
        "-i",
        "--index-url",
        "--extra-index-url",
        "--no-index",
        "-f",
        "--find-links",
        "-c",
        "--constraint",
        "-v",
        "--verbose",
        "-q",
        "--quiet",
        "-t",
        "--target",
    ];
    let tokens: Vec<&str> = rest.split_whitespace().collect();
    if tokens
        .iter()
        .any(|t| t.starts_with('-') && !KNOWN.contains(t))
    {
        return None;
    }
    Some(())
}
