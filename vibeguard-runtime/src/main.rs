mod hook_checks;
mod hook_orchestrator;
mod logging;
mod rules;
mod setup;

use std::io::{self, Read, Write};
use std::process::ExitCode;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

const USAGE: &str = "VibeGuard — native hooks and a curated rule library

Usage:
  vibeguard-runtime rules [ID|category|--json|--core]
  vibeguard-runtime hook <claude|codex> [--state-dir PATH]
  vibeguard-runtime install <claude|codex|git> [--home PATH] [--repo PATH]
  vibeguard-runtime uninstall <claude|codex|git> [--home PATH] [--repo PATH]
  vibeguard-runtime status <claude|codex|git> [--home PATH] [--repo PATH]
  vibeguard-runtime pre-push
  vibeguard-runtime --version

Install manages only its own hooks and instruction block. Git integration is
explicit and never overwrites an existing user hook. Status reports observed
facts; it does not certify trust, complete coverage, or task verification.
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(code) => ExitCode::from(code),
        Err(error) => {
            eprintln!("VibeGuard: {error}");
            // Both supported hosts interpret hook exit 2 as a visible failure.
            ExitCode::from(2)
        }
    }
}

fn run(args: &[String]) -> Result<u8> {
    match args.first().map(String::as_str) {
        None | Some("--help") if args.len() <= 1 => {
            print!("{USAGE}");
            Ok(0)
        }
        Some("--version") if args.len() == 1 => {
            println!("vibeguard-runtime {}", env!("CARGO_PKG_VERSION"));
            Ok(0)
        }
        Some("rules") => rules::run(&args[1..]),
        Some("hook") => hook_orchestrator::run(&args[1..]),
        Some("install" | "uninstall" | "status") => setup::run(&args[0], &args[1..]),
        Some("pre-push") if args.len() == 1 => hook_checks::pre_push(&read_stdin()?),
        _ => Err("unknown command or arguments; run vibeguard-runtime --help".into()),
    }
}

fn read_stdin() -> Result<String> {
    let mut input = String::new();
    io::stdin()
        .take(4 * 1024 * 1024 + 1)
        .read_to_string(&mut input)?;
    if input.len() > 4 * 1024 * 1024 {
        return Err("hook input exceeds 4 MiB".into());
    }
    Ok(input)
}

fn print_json(value: &impl serde::Serialize) -> Result<()> {
    let mut out = io::stdout().lock();
    serde_json::to_writer(&mut out, value)?;
    writeln!(out)?;
    Ok(())
}
