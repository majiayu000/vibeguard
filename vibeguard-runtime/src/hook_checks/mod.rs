pub mod bash;

use crate::Result;
use std::process::{Command, Output};

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
            let result = inspect_git(&["cat-file", "-t", &object])?;
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
        let result = inspect_git(&["merge-base", "--is-ancestor", remote, local])?;
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

pub(crate) fn inspect_git(args: &[&str]) -> Result<Output> {
    // --no-replace-objects does not disable legacy grafts. Override both the
    // default info/grafts file and any inherited GIT_GRAFT_FILE path.
    let null_file = if cfg!(windows) { "NUL" } else { "/dev/null" };
    let output = Command::new("git")
        .env("GIT_GRAFT_FILE", null_file)
        .args(["--no-replace-objects", "--no-lazy-fetch"])
        .args(args)
        .output()?;
    if output.status.code() == Some(129) {
        return Err(
            "Git object inspection requires Git 2.45 or newer with --no-lazy-fetch; upgrade Git and retry"
                .into(),
        );
    }
    Ok(output)
}

fn valid_oid(value: &str) -> bool {
    matches!(value.len(), 40 | 64) && value.bytes().all(|b| b.is_ascii_hexdigit())
}
