pub mod core;
pub mod file_changes;
pub mod hooks;
pub mod policy;
mod proxy;
pub mod strategies;

use crate::codex_app_server::core::{GateStrategy, NoopGateStrategy};
use crate::codex_app_server::proxy::run_proxy;
use crate::codex_app_server::strategies::VibeGuardGateStrategy;
use std::error::Error;
use std::path::PathBuf;

#[derive(Debug)]
struct Args {
    repo_dir: PathBuf,
    strategy: String,
    codex_command: String,
}

pub fn run(args: &[String]) -> Result<(), Box<dyn Error>> {
    let args = parse_args(args)?;
    let strategy: Box<dyn GateStrategy> = match args.strategy.as_str() {
        "noop" => Box::new(NoopGateStrategy),
        "vibeguard" => Box::new(VibeGuardGateStrategy::new(&args.repo_dir, None)?),
        other => return Err(format!("unsupported strategy: {other}").into()),
    };

    run_proxy(strategy, &args.codex_command)
}

fn parse_args(args: &[String]) -> Result<Args, Box<dyn Error>> {
    let mut repo_dir: Option<PathBuf> = None;
    let mut strategy = "vibeguard".to_string();
    let mut codex_command = "codex app-server".to_string();
    let mut idx = 0;
    while idx < args.len() {
        match args[idx].as_str() {
            "-h" | "--help" => {
                print_help();
                std::process::exit(0);
            }
            "--repo-dir" => {
                idx += 1;
                repo_dir = Some(PathBuf::from(
                    args.get(idx).ok_or("--repo-dir requires a value")?,
                ));
            }
            "--strategy" => {
                idx += 1;
                strategy = args.get(idx).ok_or("--strategy requires a value")?.clone();
            }
            "--codex-command" => {
                idx += 1;
                codex_command = args
                    .get(idx)
                    .ok_or("--codex-command requires a value")?
                    .clone();
            }
            arg if arg.starts_with("--repo-dir=") => {
                repo_dir = Some(PathBuf::from(arg.trim_start_matches("--repo-dir=")));
            }
            arg if arg.starts_with("--strategy=") => {
                strategy = arg.trim_start_matches("--strategy=").to_string();
            }
            arg if arg.starts_with("--codex-command=") => {
                codex_command = arg.trim_start_matches("--codex-command=").to_string();
            }
            arg => return Err(format!("unknown argument: {arg}").into()),
        }
        idx += 1;
    }

    Ok(Args {
        repo_dir: repo_dir.unwrap_or_else(default_repo_dir),
        strategy,
        codex_command,
    })
}

fn print_help() {
    println!(
        "Usage: vibeguard-runtime codex-app-server-wrapper [--repo-dir DIR] [--strategy vibeguard|noop] [--codex-command CMD]"
    );
}

fn default_repo_dir() -> PathBuf {
    if let Ok(home) = std::env::var("HOME") {
        let repo_path = PathBuf::from(home).join(".vibeguard/repo-path");
        if let Ok(text) = std::fs::read_to_string(repo_path) {
            let path = text.trim();
            if !path.is_empty() {
                return PathBuf::from(path);
            }
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_string()).collect()
    }

    #[test]
    fn parse_args_uses_vibeguard_defaults() {
        let args = parse_args(&[]).expect("default args should parse");

        assert_eq!(args.strategy, "vibeguard");
        assert_eq!(args.codex_command, "codex app-server");
        assert!(!args.repo_dir.as_os_str().is_empty());
    }

    #[test]
    fn parse_args_accepts_inline_and_separate_values() {
        let args = parse_args(&strings(&[
            "--repo-dir=/tmp/vibeguard",
            "--strategy",
            "noop",
            "--codex-command=codex app-server --json",
        ]))
        .expect("explicit args should parse");

        assert_eq!(args.repo_dir, PathBuf::from("/tmp/vibeguard"));
        assert_eq!(args.strategy, "noop");
        assert_eq!(args.codex_command, "codex app-server --json");
    }

    #[test]
    fn parse_args_rejects_unknown_args() {
        let err = parse_args(&strings(&["--missing"])).expect_err("unknown arg should fail");

        assert!(err.to_string().contains("unknown argument: --missing"));
    }
}
