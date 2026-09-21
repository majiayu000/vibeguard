use serde_json::{Value, json};
use std::path::{Component, Path, PathBuf};

const V1_START: &str = "<!-- vibeguard-start -->";
const V1_END: &str = "<!-- vibeguard-end -->";

pub(super) fn markdown_findings(path: &Path, text: &str) -> Vec<Value> {
    let mut fence: Option<(u8, usize)> = None;
    let mut exact_starts = Vec::new();
    let mut exact_ends = Vec::new();
    let mut fenced_mention = false;
    let mut prose_lines = Vec::new();
    for (index, segment) in text.split_inclusive('\n').enumerate() {
        let line = segment.trim_end_matches(['\r', '\n']);
        let trimmed = line.trim_start_matches(' ');
        let indent = line.len() - trimmed.len();
        let run = trimmed.as_bytes().first().copied().and_then(|marker| {
            let length = trimmed.bytes().take_while(|byte| *byte == marker).count();
            (indent <= 3 && matches!(marker, b'`' | b'~') && length >= 3).then_some((
                marker,
                length,
                &trimmed[length..],
            ))
        });
        if let Some((marker, minimum)) = fence {
            if run.is_some_and(|(candidate, length, rest)| {
                candidate == marker && length >= minimum && rest.trim().is_empty()
            }) {
                fence = None;
            } else if mentions_legacy_markdown(line) {
                fenced_mention = true;
            }
            continue;
        } else if let Some((marker, length, rest)) = run
            && (marker != b'`' || !rest.contains('`'))
        {
            fence = Some((marker, length));
            continue;
        }
        if line == V1_START {
            exact_starts.push(index);
        } else if line == V1_END {
            exact_ends.push(index);
        } else if mentions_legacy_markdown(line) {
            prose_lines.push(index);
        }
    }
    let mut findings = Vec::new();
    let owned = exact_starts.len() == 1 && exact_ends.len() == 1 && exact_starts[0] < exact_ends[0];
    if owned {
        findings.push(finding(
            "owned",
            path,
            "markdown",
            "standalone v1 managed region",
            None,
        ));
    } else if !exact_starts.is_empty() || !exact_ends.is_empty() {
        findings.push(suspected(
            path,
            "markdown",
            "unpaired or repeated v1 markers",
        ));
    }
    let inside_owned = |line: usize| owned && exact_starts[0] < line && line < exact_ends[0];
    if fenced_mention || prose_lines.iter().any(|line| !inside_owned(*line)) {
        findings.push(suspected(
            path,
            "markdown",
            "v1 names appear in prose or a fenced example",
        ));
    }
    findings
}

pub(super) fn crontab_findings(text: &str) -> Vec<Value> {
    let mut findings = Vec::new();
    for (index, line) in text.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let location = format!("crontab:{index}");
        match shell_words(trimmed) {
            Ok(words) if words.iter().any(|word| owned_word(word)) => findings.push(json!({
                "evidence":"owned",
                "category":"scheduler",
                "location":location,
                "detail":"account crontab contains a v1 command path"
            })),
            Ok(_) if mentions_v1(trimmed) => findings.push(json!({
                "evidence":"suspected",
                "category":"scheduler",
                "location":location,
                "detail":"account crontab mentions v1 names without an owned path"
            })),
            Err(()) if mentions_v1(trimmed) => findings.push(json!({
                "evidence":"suspected",
                "category":"scheduler",
                "location":location,
                "detail":"crontab line has unbalanced quotes and mentions v1 names; it was not executed"
            })),
            _ => {}
        }
    }
    findings
}

pub(super) fn classify_command(command: &str) -> Option<&'static str> {
    if is_v2_hook_command(command) {
        return None;
    }
    match shell_words(command) {
        Ok(words) if words.iter().any(|word| owned_word(word)) => Some("owned"),
        Ok(_) if mentions_v1(command) => Some("suspected"),
        Err(()) if mentions_v1(command) => Some("suspected"),
        _ => None,
    }
}

pub(super) fn command_detail(command: &str, evidence: &str) -> String {
    if evidence == "owned" {
        shell_words(command)
            .ok()
            .and_then(|words| words.into_iter().find(|word| owned_word(word)))
            .map(|word| format!("owned v1 command path {word}"))
            .unwrap_or_else(|| "owned v1 command path".into())
    } else {
        "mentions v1 names without an owned path; not executed".into()
    }
}

fn is_v2_hook_command(command: &str) -> bool {
    let Ok(words) = shell_words(command) else {
        return false;
    };
    let mut index = 0;
    while words.get(index).is_some_and(|word| is_assignment(word)) {
        index += 1;
    }
    let Some(binary) = words.get(index) else {
        return false;
    };
    let name = binary.rsplit(['/', '\\']).next().unwrap_or(binary.as_str());
    (name == "vibeguard-runtime" || name == "vibeguard-runtime.exe")
        && words.get(index + 1).map(String::as_str) == Some("hook")
        && matches!(
            words.get(index + 2).map(String::as_str),
            Some("claude" | "codex")
        )
        && words.get(index + 3).map(String::as_str) == Some("--state-dir")
        && words.len() == index + 5
}

fn is_assignment(word: &str) -> bool {
    let Some((name, _)) = word.split_once('=') else {
        return false;
    };
    let mut chars = name.chars();
    matches!(chars.next(), Some(char) if char.is_ascii_alphabetic() || char == '_')
        && chars.all(|char| char.is_ascii_alphanumeric() || char == '_')
}

pub(super) fn owned_word(word: &str) -> bool {
    let trimmed = word.trim_end_matches('/');
    [
        "/run-hook.sh",
        "/run-hook-codex.sh",
        "/run-hook-gemini.sh",
        "/pre-commit-guard.sh",
        "/hooks/git/pre-push",
        "/.vibeguard/pre-commit",
        "/.vibeguard/pre-push",
        "/scripts/gc/gc-scheduled.sh",
    ]
    .iter()
    .any(|ending| trimmed.ends_with(ending))
        || trimmed.contains("/.vibeguard/installed/hooks/")
}

fn mentions_legacy_markdown(line: &str) -> bool {
    if line == "<!-- vibeguard-core:start -->" || line == "<!-- vibeguard-core:end -->" {
        return false;
    }
    let current = line
        .replace("vibeguard-core", "")
        .replace("vibeguard-runtime", "")
        .replace(".vibeguard/bin", "")
        .replace(".vibeguard/state", "");
    current.contains("vibeguard-start")
        || current.contains("vibeguard-end")
        || current.contains("run-hook")
        || current.contains("pre-bash-guard.sh")
        || current.contains("pre-commit-guard.sh")
        || current.contains("gc-scheduled.sh")
        || current.contains(".vibeguard/installed")
        || current.contains(".vibeguard/pre-commit")
        || current.contains(".vibeguard/pre-push")
        || current.contains(".vibeguard/dist")
}

pub(super) fn mentions_v1(text: &str) -> bool {
    text.contains("vibeguard")
        || text.contains("run-hook")
        || text.contains("pre-bash-guard.sh")
        || text.contains("pre-commit-guard.sh")
        || text.contains("gc-scheduled.sh")
}

pub(super) fn v1_hook_body(text: &str) -> bool {
    text.contains("pre-commit-guard.sh")
        || text.contains("hooks/git/pre-push")
        || text.contains("VibeGuard Pre-Commit Hook Wrapper")
        || text.contains("VibeGuard Pre-Push Hook Wrapper")
}

fn shell_words(input: &str) -> Result<Vec<String>, ()> {
    let mut words = Vec::new();
    let mut current = String::new();
    let mut chars = input.chars().peekable();
    let mut quote: Option<char> = None;
    let mut in_word = false;
    while let Some(char) = chars.next() {
        match quote {
            Some('\'') => {
                in_word = true;
                if char == '\'' {
                    quote = None;
                } else {
                    current.push(char);
                }
            }
            Some('"') => {
                in_word = true;
                if char == '\\' {
                    let Some(next) = chars.next() else {
                        return Err(());
                    };
                    current.push(next);
                } else if char == '"' {
                    quote = None;
                } else {
                    current.push(char);
                }
            }
            Some(_) => return Err(()),
            None if char == '\\' => {
                let Some(next) = chars.next() else {
                    return Err(());
                };
                current.push(next);
                in_word = true;
            }
            None if char == '\'' || char == '"' => {
                quote = Some(char);
                in_word = true;
            }
            None if char.is_whitespace() => {
                if in_word {
                    words.push(std::mem::take(&mut current));
                    in_word = false;
                }
            }
            None => {
                current.push(char);
                in_word = true;
            }
        }
    }
    if quote.is_some() {
        return Err(());
    }
    if in_word {
        words.push(current);
    }
    Ok(words)
}

pub(super) fn lexical_join(base: &Path, target: &Path) -> String {
    let combined = if target.is_absolute() {
        target.to_path_buf()
    } else {
        base.join(target)
    };
    let mut out = PathBuf::new();
    for component in combined.components() {
        match component {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out.to_string_lossy().into_owned()
}

pub(super) fn finding(
    evidence: &str,
    path: &Path,
    category: &str,
    detail: &str,
    event: Option<&str>,
) -> Value {
    let mut value = json!({
        "evidence": evidence,
        "category": category,
        "location": path_text(path),
        "detail": detail,
    });
    if let Some(event) = event {
        value["event"] = json!(event);
    }
    value
}

pub(super) fn suspected(path: &Path, category: &str, detail: &str) -> Value {
    finding("suspected", path, category, detail, None)
}

pub(super) fn not_checked(path: &Path, category: &str, detail: &str) -> Value {
    finding("not_checked", path, category, detail, None)
}

pub(super) fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_classification_keeps_quotes_and_ignores_current_v2() {
        assert_eq!(
            classify_command("bash '/home/user/.vibeguard/run-hook.sh' pre-bash-guard.sh"),
            Some("owned")
        );
        assert_eq!(
            classify_command(
                "bash \"/home/user/my vibeguard/scripts/gc/gc-scheduled.sh\" --scheduled"
            ),
            Some("owned")
        );
        assert_eq!(
            classify_command("'/opt/vibeguard-runtime' hook claude --state-dir '/state'"),
            None
        );
        assert_eq!(classify_command("echo user-hook"), None);
        assert_eq!(classify_command("echo vibeguard"), Some("suspected"));
        assert_eq!(
            classify_command("bash '/home/user/.vibeguard/run-hook.sh"),
            Some("suspected")
        );
    }

    #[test]
    fn crontab_lines_ignore_comments_and_keep_quoted_paths() {
        let text = "\
# 0 3 * * 0 /bin/bash /missing/vibeguard/scripts/gc/gc-scheduled.sh
0 3 * * 0 /bin/bash \"/missing/my vibeguard/scripts/gc/gc-scheduled.sh\" --scheduled
@weekly echo vibeguard
15 1 * * 1 /usr/bin/backup
";
        let findings = crontab_findings(text);
        assert_eq!(findings.len(), 2);
        assert_eq!(findings[0]["evidence"], "owned");
        assert_eq!(findings[0]["location"], "crontab:1");
        assert_eq!(findings[1]["evidence"], "suspected");
        assert_eq!(findings[1]["location"], "crontab:2");
    }

    #[test]
    fn markdown_regions_do_not_own_fenced_examples() {
        let path = Path::new("CLAUDE.md");
        let text = "\
User note mentioning run-hook.sh
<!-- vibeguard-start -->
old rules
<!-- vibeguard-end -->
```
<!-- vibeguard-start -->
<!-- vibeguard-end -->
```
";
        let findings = markdown_findings(path, text);
        assert!(
            findings
                .iter()
                .any(|finding| finding["evidence"] == "owned")
        );
        assert!(
            findings
                .iter()
                .any(|finding| finding["evidence"] == "suspected")
        );
        let fenced_only = "```md\n<!-- vibeguard-start -->\n<!-- vibeguard-end -->\n```\n";
        let findings = markdown_findings(path, fenced_only);
        assert!(
            findings
                .iter()
                .all(|finding| finding["evidence"] == "suspected")
        );
    }
}
