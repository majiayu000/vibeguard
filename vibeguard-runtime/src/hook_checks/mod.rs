pub mod bash;

use crate::Result;
use std::process::Command;

pub fn pre_push(input: &str) -> Result<u8> {
    for line in input.lines().filter(|line| !line.trim().is_empty()) {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() != 4 || !valid_oid(fields[1]) || !valid_oid(fields[3]) {
            return Err("invalid Git pre-push input".into());
        }
        let (local, remote) = (fields[1], fields[3]);
        if local.bytes().all(|b| b == b'0') {
            eprintln!("VibeGuard: remote branch deletion is blocked by this Git hook.");
            return Ok(1);
        }
        if remote.bytes().all(|b| b == b'0') {
            continue;
        }
        let result = Command::new("git")
            .args(["merge-base", "--is-ancestor", remote, local])
            .output()?;
        match result.status.code() {
            Some(0) => {}
            Some(1) => {
                eprintln!("VibeGuard: non-fast-forward push is blocked by this Git hook.");
                return Ok(1);
            }
            _ => {
                return Err(
                    "could not determine Git ancestry; fetch the remote objects and retry".into(),
                );
            }
        }
    }
    Ok(0)
}

fn valid_oid(value: &str) -> bool {
    matches!(value.len(), 40 | 64) && value.bytes().all(|b| b.is_ascii_hexdigit())
}
