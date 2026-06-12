use std::path::Path;

use crate::hook_checks_common::{append_jsonl, read_stdin};

type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;

pub fn run(args: &[String]) -> Result {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime append-jsonl <log-file>".into());
    }

    let line = read_valid_jsonl_line("append-jsonl")?;
    append_jsonl(Path::new(&args[0]), &line)?;
    Ok(())
}

pub fn run_mirror(args: &[String]) -> Result {
    if args.len() != 2 {
        return Err(
            "Usage: vibeguard-runtime append-jsonl-mirror <primary-log-file> <mirror-log-file>"
                .into(),
        );
    }

    let line = read_valid_jsonl_line("append-jsonl-mirror")?;
    let primary = Path::new(&args[0]);
    let mirror = Path::new(&args[1]);

    append_jsonl(primary, &line).map_err(|err| {
        format!(
            "primary JSONL append failed for {}: {}",
            primary.display(),
            err
        )
    })?;

    if mirror != primary {
        append_jsonl(mirror, &line).map_err(|err| {
            format!(
                "mirror JSONL append failed for {}: {}",
                mirror.display(),
                err
            )
        })?;
    }

    Ok(())
}

fn read_valid_jsonl_line(command_name: &str) -> Result<String> {
    let mut line = read_stdin()?;
    if line.ends_with('\n') {
        line.pop();
        if line.ends_with('\r') {
            line.pop();
        }
    }

    if line.is_empty() {
        return Err(format!("{command_name} input must not be empty").into());
    }
    if line.contains('\n') || line.contains('\r') {
        return Err(format!("{command_name} input must be exactly one JSONL line").into());
    }

    let value = serde_json::from_str::<serde_json::Value>(&line)?;
    if !value.is_object() {
        return Err(format!("{command_name} input must be a JSON object").into());
    }
    Ok(line)
}
