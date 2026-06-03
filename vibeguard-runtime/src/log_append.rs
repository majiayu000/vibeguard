use std::path::Path;

use crate::hook_checks_common::{append_jsonl, read_stdin};

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

pub fn run(args: &[String]) -> Result {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime append-jsonl <log-file>".into());
    }

    let mut line = read_stdin()?;
    if line.ends_with('\n') {
        line.pop();
        if line.ends_with('\r') {
            line.pop();
        }
    }

    if line.is_empty() {
        return Err("append-jsonl input must not be empty".into());
    }
    if line.contains('\n') || line.contains('\r') {
        return Err("append-jsonl input must be exactly one JSONL line".into());
    }

    let value = serde_json::from_str::<serde_json::Value>(&line)?;
    if !value.is_object() {
        return Err("append-jsonl input must be a JSON object".into());
    }
    append_jsonl(Path::new(&args[0]), &line)?;
    Ok(())
}
