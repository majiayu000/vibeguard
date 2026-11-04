//! Refuses a commit that leaves a source file above the line limit and longer than it
//! was. Every way of writing a file, from any Agent or person, ends at a commit, so
//! this needs no guess about commands and no list of known large files: comparing with
//! the previous commit means a file already above the limit can only get shorter.

use super::file_size::{MAX_LINES, count_lines, is_source};
use super::inspect_git;
use crate::Result;

/// Lines of `spec`, or `None` when Git can't produce it (absent from that commit, a
/// submodule, an object missing from a partial clone).
fn lines_of(spec: &str) -> Result<Option<usize>> {
    let output = inspect_git(&["show", spec])?;
    Ok(output
        .status
        .success()
        .then(|| count_lines(&String::from_utf8_lossy(&output.stdout))))
}

fn resolves(rev: &str) -> Result<bool> {
    Ok(inspect_git(&["rev-parse", "--verify", "-q", rev])?
        .status
        .success())
}

/// What the staged content is compared with: `HEAD`, or the empty tree in a new
/// repository.
fn base() -> Result<String> {
    if resolves("HEAD^{commit}")? {
        return Ok("HEAD".into());
    }
    let tree = inspect_git(&["hash-object", "-t", "tree", "/dev/null"])?;
    if !tree.status.success() {
        return Err("could not compute Git's empty tree".into());
    }
    Ok(String::from_utf8(tree.stdout)?.trim().to_owned())
}

/// Staged source files as (status, path now, path to compare with). A rename is compared
/// with its old name, so moving a large file isn't taken for writing a new one.
fn staged(base: &str) -> Result<Vec<(char, String, String)>> {
    let args = [
        "diff",
        "--cached",
        "--name-status",
        "-z",
        "-M",
        "--no-ext-diff",
        base,
    ];
    let output = inspect_git(&args)?;
    if !output.status.success() {
        return Err("could not read the staged changes".into());
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let mut fields = text.split('\0').filter(|f| !f.is_empty());
    let mut files = vec![];
    while let Some(status) = fields.next() {
        let kind = status.chars().next().unwrap_or('?');
        let first = fields.next().ok_or("malformed Git status")?.to_owned();
        let (now, old) = if matches!(kind, 'R' | 'C') {
            (
                fields.next().ok_or("malformed Git status")?.to_owned(),
                first,
            )
        } else {
            (first.clone(), first)
        };
        if kind != 'D' && is_source(&now) {
            files.push((kind, now, old));
        }
    }
    Ok(files)
}

/// Every commit on the machine comes through here, so a failure of this check warns
/// instead of stopping them all.
pub fn run() -> Result<u8> {
    check().or_else(|error| {
        eprintln!("VibeGuard: line limit not checked for this commit: {error}");
        Ok(0)
    })
}

fn check() -> Result<u8> {
    // Someone else's project has its own conventions: `git config vibeguard.sizeLimit false`.
    let enabled = inspect_git(&["config", "--type=bool", "--get", "vibeguard.sizeLimit"])?;
    if enabled.stdout.trim_ascii() == b"false" {
        return Ok(0);
    }
    let base = base()?;
    // Concluding a merge: what either side already had isn't this commit's growth.
    let mut parents = vec![base.clone()];
    if resolves("MERGE_HEAD")? {
        parents.push("MERGE_HEAD".into());
    }
    let mut refused = vec![];
    for (kind, now, old) in staged(&base)? {
        let Some(after) = lines_of(&format!(":{now}"))? else {
            continue;
        };
        if after <= MAX_LINES {
            continue;
        }
        let mut before = 0;
        if kind != 'A' && kind != 'C' {
            // A file that should exist but can't be read isn't evidence of growth.
            let Some(lines) = lines_of(&format!("{base}:{old}"))? else {
                continue;
            };
            before = lines;
        }
        for parent in &parents[1..] {
            before = before.max(lines_of(&format!("{parent}:{now}"))?.unwrap_or(0));
        }
        if after > before {
            refused.push(if before > MAX_LINES {
                format!("  {now}: grew from {before} to {after} lines")
            } else {
                format!("  {now}: {after} lines")
            });
        }
    }
    if refused.is_empty() {
        return Ok(0);
    }
    eprintln!(
        "VibeGuard: commit refused, source files above the {MAX_LINES}-line limit:\n{}\nMove code out by responsibility instead of adding to these files.",
        refused.join("\n")
    );
    Ok(1)
}
