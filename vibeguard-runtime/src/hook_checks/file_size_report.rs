//! After a shell command, tells the Agent which source files now sit above the line
//! limit and longer than they were committed. The Pre-edit denial in `file_size` can't
//! see a script run from the shell, so this looks at what the repository holds instead
//! of guessing from the command text.
//!
//! This is a notice, not a decision: the command has already run, and any failure here
//! (no Git, not a repository, unreadable state) means no notice and nothing else.

use super::file_size::{MAX_LINES, count_lines, is_source};
use crate::setup::support::{read_optional, write_atomic};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const STATE_FILE: &str = "file-size-reports.json";

struct Grown {
    path: String,
    before: usize,
    after: usize,
}

/// The notice for this command, if a file grew past the limit since it was last reported.
pub fn notice(cwd: &Path, command: Option<&str>, state_dir: Option<&Path>) -> Option<String> {
    let command = command.unwrap_or_default();
    let mut roots = BTreeSet::new();
    for dir in candidate_dirs(cwd, command) {
        if let Some(root) = repository_root(&dir) {
            roots.insert(root);
        }
    }
    let mut seen = state_dir.map(load).unwrap_or_default();
    // Worktrees come and go; a removed one's files have nothing left to tell.
    seen.retain(|path, _| Path::new(path).exists());
    let mut fresh = vec![];
    for root in &roots {
        let grown = scan(root, command);
        // A file fixed or committed leaves the record, so growing it again is news.
        let prefix = format!("{}/", root.display());
        seen.retain(|path, _| !path.starts_with(&prefix));
        for file in grown {
            seen.insert(file.path.clone(), file.after);
            fresh.push(file);
        }
    }
    let previous = state_dir.map(load).unwrap_or_default();
    fresh.retain(|file| previous.get(&file.path) != Some(&file.after));
    if let Some(dir) = state_dir
        && seen != previous
        && let Ok(text) = serde_json::to_vec(&seen)
    {
        // Losing this only repeats a notice.
        let _ = write_atomic(&dir.join(STATE_FILE), &text, 0o600);
    }
    if fresh.is_empty() {
        return None;
    }
    let lines: Vec<String> = fresh
        .iter()
        .map(|f| {
            if f.before > MAX_LINES {
                format!(
                    "{} grew from {} to {} lines, above the {MAX_LINES}-line limit.",
                    f.path, f.before, f.after
                )
            } else {
                format!(
                    "{} now has {} lines, above the {MAX_LINES}-line limit.",
                    f.path, f.after
                )
            }
        })
        .collect();
    Some(format!(
        "VibeGuard: {} Move the new code out by responsibility instead of adding to these files.",
        lines.join(" ")
    ))
}

fn load(state_dir: &Path) -> BTreeMap<String, usize> {
    read_optional(&state_dir.join(STATE_FILE))
        .ok()
        .flatten()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

/// The hook's working directory, plus the places the command says it works in: Agents
/// often run `cd ../other-worktree; python3 ...`, and the hook's cwd doesn't follow.
fn candidate_dirs(cwd: &Path, command: &str) -> Vec<PathBuf> {
    let words: Vec<&str> = command
        .split(|c: char| c.is_whitespace() || matches!(c, ';' | '&' | '|' | '(' | ')'))
        .map(|w| w.trim_matches(|c| c == '\'' || c == '"'))
        .filter(|w| !w.is_empty())
        .collect();
    let mut dirs = vec![cwd.to_path_buf()];
    for (i, word) in words.iter().enumerate() {
        let after_cd = i > 0 && matches!(words[i - 1], "cd" | "-C");
        // `p='/abs/file.rs'` names a file the same way a bare path does.
        let value = word
            .rsplit('=')
            .next()
            .unwrap_or(word)
            .trim_matches(|c| c == '\'' || c == '"');
        if after_cd {
            dirs.extend(resolve(cwd, word));
        } else if value.starts_with(['/', '~'])
            && is_source(value)
            && let Some(file) = resolve(cwd, value)
            && let Some(parent) = file.parent()
        {
            dirs.push(parent.to_path_buf());
        }
    }
    dirs
}

fn resolve(cwd: &Path, word: &str) -> Option<PathBuf> {
    if word.contains('$') || word.contains('`') {
        return None;
    }
    if let Some(rest) = word.strip_prefix("~/") {
        return Some(PathBuf::from(std::env::var_os("HOME")?).join(rest));
    }
    Some(cwd.join(word))
}

fn git(root: &Path, args: &[&str]) -> Option<Vec<u8>> {
    let output = Command::new("git")
        // A hook must not take the index lock from the commands around it, or start
        // a repository's filesystem monitor.
        .env("GIT_OPTIONAL_LOCKS", "0")
        .args(["-c", "core.fsmonitor=false", "-C"])
        .arg(root)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    output.status.success().then_some(output.stdout)
}

fn repository_root(dir: &Path) -> Option<PathBuf> {
    let out = git(dir, &["rev-parse", "--show-toplevel"])?;
    Some(PathBuf::from(String::from_utf8(out).ok()?.trim_end()))
}

fn scan(root: &Path, command: &str) -> Vec<Grown> {
    // A command that also commits leaves nothing uncommitted to compare, so compare
    // with the commit before it.
    let base = if command.contains("git commit")
        && git(root, &["rev-parse", "--verify", "-q", "HEAD~1"]).is_some()
    {
        "HEAD~1"
    } else {
        "HEAD"
    };
    let mut changed = BTreeSet::new();
    if let Some(out) = git(
        root,
        &["status", "--porcelain", "-z", "--untracked-files=all"],
    ) {
        let text = String::from_utf8_lossy(&out);
        let mut entries = text.split('\0');
        while let Some(entry) = entries.next() {
            // `XY path`; a rename or copy is followed by its old path as its own entry.
            if entry.starts_with(['R', 'C']) {
                entries.next();
            }
            changed.extend(entry.get(3..).filter(|p| is_source(p)).map(str::to_owned));
        }
    }
    if base != "HEAD"
        && let Some(out) = git(root, &["diff", "--name-only", "-z", base, "HEAD"])
    {
        changed.extend(
            String::from_utf8_lossy(&out)
                .split('\0')
                .filter(|p| is_source(p))
                .map(str::to_owned),
        );
    }
    let mut grown = vec![];
    for rel in changed {
        let path = root.join(&rel);
        let Ok(bytes) = std::fs::read(&path) else {
            continue;
        };
        let after = count_lines(&String::from_utf8_lossy(&bytes));
        if after <= MAX_LINES {
            continue;
        }
        let before = git(root, &["show", &format!("{base}:{rel}")])
            .map_or(0, |old| count_lines(&String::from_utf8_lossy(&old)));
        if after > before {
            grown.push(Grown {
                path: path.display().to_string(),
                before,
                after,
            });
        }
    }
    grown
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Repo {
        dir: PathBuf,
        state: PathBuf,
    }

    impl Repo {
        fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let base = std::env::temp_dir().join(format!(
                "vibeguard-size-report-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let (dir, state) = (base.join("repo"), base.join("state"));
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::create_dir_all(&state).unwrap();
            let dir = dir.canonicalize().unwrap();
            let repo = Repo { dir, state };
            repo.run(&["init", "-q"]);
            repo.run(&["config", "user.email", "t@example.com"]);
            repo.run(&["config", "user.name", "t"]);
            repo.write("big.rs", 900);
            repo.write("small.rs", 10);
            repo.write("big.md", 900);
            repo.commit();
            repo
        }
        fn run(&self, args: &[&str]) {
            let ok = Command::new("git")
                .arg("-C")
                .arg(&self.dir)
                .args(args)
                .status()
                .unwrap();
            assert!(ok.success());
        }
        fn write(&self, name: &str, lines: usize) {
            std::fs::write(self.dir.join(name), "x\n".repeat(lines)).unwrap();
        }
        fn commit(&self) {
            self.run(&["add", "-A"]);
            self.run(&["commit", "-qm", "c"]);
        }
        fn notice(&self, command: &str) -> Option<String> {
            notice(&self.dir, Some(command), Some(&self.state))
        }
    }

    impl Drop for Repo {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(self.dir.parent().unwrap());
        }
    }

    #[test]
    fn growth_is_told_once_per_size() {
        let repo = Repo::new();
        assert_eq!(repo.notice("ls"), None);
        repo.write("big.rs", 950);
        let text = repo.notice("python3 x.py").unwrap();
        assert!(text.contains("big.rs grew from 900 to 950 lines"), "{text}");
        assert_eq!(repo.notice("ls"), None, "the next command is not news");
        repo.write("big.rs", 960);
        assert!(repo.notice("ls").unwrap().contains("to 960"));
    }

    #[test]
    fn only_growth_past_the_limit_of_source_files_counts() {
        let repo = Repo::new();
        repo.write("big.rs", 850);
        repo.write("small.rs", 800);
        repo.write("big.md", 2000);
        assert_eq!(repo.notice("sh edit.sh"), None);
    }

    #[test]
    fn a_new_or_newly_oversized_file_counts() {
        let repo = Repo::new();
        repo.write("new.rs", 801);
        repo.write("small.rs", 801);
        let text = repo.notice("sh edit.sh").unwrap();
        assert!(text.contains("new.rs now has 801 lines"), "{text}");
        assert!(text.contains("small.rs now has 801 lines"), "{text}");
    }

    #[test]
    fn a_renamed_and_grown_file_is_seen_under_its_new_name() {
        let repo = Repo::new();
        repo.run(&["mv", "big.rs", "moved.rs"]);
        repo.write("moved.rs", 950);
        let text = repo.notice("sh x").unwrap();
        assert!(text.contains("moved.rs now has 950 lines"), "{text}");
        assert!(!text.contains("big.rs"), "{text}");
    }

    #[test]
    fn a_command_that_also_commits_is_still_seen() {
        let repo = Repo::new();
        repo.write("big.rs", 950);
        repo.commit();
        assert_eq!(repo.notice("ls"), None, "already committed by someone else");
        assert!(
            repo.notice("sed -i x big.rs && git commit -m x")
                .unwrap()
                .contains("grew from 900 to 950")
        );
    }

    #[test]
    fn a_command_working_in_another_directory_is_followed() {
        let repo = Repo::new();
        let other = Repo::new();
        repo.write("big.rs", 950);
        let dir = repo.dir.display();
        for command in [
            format!("cd {dir}; python3 - <<'E'"),
            format!("cd '{dir}' && sh x"),
            format!("git -C {dir} status"),
            format!("p='{dir}/big.rs'; python3 x"),
        ] {
            std::fs::remove_file(other.state.join(STATE_FILE)).ok();
            let text = notice(&other.dir, Some(&command), Some(&other.state));
            assert!(text.is_some_and(|t| t.contains("grew")), "{command}");
        }
    }

    #[test]
    fn committing_the_file_clears_the_record_so_growing_it_again_is_news() {
        let repo = Repo::new();
        repo.write("big.rs", 950);
        assert!(repo.notice("x").is_some());
        repo.commit();
        assert_eq!(repo.notice("ls"), None);
        repo.write("big.rs", 900);
        repo.commit();
        repo.write("big.rs", 950);
        assert!(repo.notice("x").is_some());
    }

    #[test]
    fn outside_a_repository_there_is_no_notice() {
        let dir = std::env::temp_dir();
        assert_eq!(notice(&dir, Some("ls"), None), None);
        assert_eq!(notice(Path::new("/nowhere/at/all"), None, None), None);
    }
}
