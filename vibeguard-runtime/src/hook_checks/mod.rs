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
        let remote_ref = fields[2];
        if local.bytes().all(|b| b == b'0') {
            eprintln!(
                "VibeGuard: deletion of remote ref {remote_ref} is blocked by this Git hook."
            );
            return Ok(1);
        }
        if local == remote {
            continue;
        }
        let new_ref = remote.bytes().all(|b| b == b'0');
        if remote_ref.starts_with("refs/tags/") {
            if !new_ref {
                eprintln!(
                    "VibeGuard: replacement of remote tag {remote_ref} is blocked by this Git hook."
                );
                return Ok(1);
            }
            continue;
        }
        let branch = remote_ref.starts_with("refs/heads/");
        if new_ref && !branch {
            continue;
        }
        for oid in [local, remote]
            .into_iter()
            .take(if new_ref { 1 } else { 2 })
        {
            let object = if branch {
                oid.to_string()
            } else {
                format!("{oid}^{{}}")
            };
            let result = Command::new("git")
                .args(["cat-file", "-t", &object])
                .output()?;
            if !result.status.success() {
                return Err(
                    "could not inspect Git object; fetch the remote objects and retry".into(),
                );
            }
            if result.stdout != b"commit\n" {
                let requirement = if branch {
                    "must target commits directly"
                } else {
                    "must resolve to commits for ancestry checks"
                };
                eprintln!("VibeGuard: update of {remote_ref} is blocked: objects {requirement}.");
                return Ok(1);
            }
        }
        if new_ref {
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
