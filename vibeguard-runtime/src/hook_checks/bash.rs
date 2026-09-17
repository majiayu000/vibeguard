//! Limited recognition of destructive command spellings, not a shell sandbox.
use regex::Regex;

fn matches(pattern: &str, text: &str) -> bool {
    Regex::new(pattern)
        .expect("built-in command pattern")
        .is_match(text)
}

pub fn blocked_reason(command: &str) -> Option<&'static str> {
    let command = strip_heredoc_bodies(command);
    let command = command.replace("\".\"", ".").replace("'.'", ".");
    let masked = mask_quoted_content(&command);
    let paths = mask_content(&command, false);
    // Match actual command positions. Quoted text and comments are blanked,
    // preserving byte offsets so path arguments can be inspected separately.
    let starts = Regex::new(
        r"(?m)(^|[;&|\n])\s*(?:env\s+)?(?:[A-Za-z_][A-Za-z0-9_]*=[^\s;&|]*\s+)*(?:command\s+)?(?:sudo\s+)?(?P<name>\\?rm|git)\s+(?P<args>[^;&|\n]*)",
    ).expect("built-in command position pattern");
    for captures in starts.captures_iter(&masked) {
        let args = captures.name("args").expect("args capture");
        let visible = args.as_str();
        if &captures["name"] == "git" {
            if matches(
                r"^(checkout|restore)\s+(?:--\s+)?\.\s*(?:[<>].*)?$",
                visible,
            ) {
                return Some(
                    "Bulk git checkout/restore of the working tree is blocked. Inspect the diff and target the intended files.",
                );
            }
            if matches(r"^clean\s+", visible)
                && matches(r"(^|\s)-[A-Za-z]*f[A-Za-z]*(\s|$)", visible)
                && !matches(r"(^|\s)(--dry-run|-([A-Za-z]*n[A-Za-z]*))(\s|$)", visible)
            {
                return Some(
                    "Forced git clean is blocked. Preview with git clean -n and select the files to remove.",
                );
            }
        } else if matches(
            r"^((-[A-Za-z]*([rR][A-Za-z]*f|f[A-Za-z]*[rR]))|(--recursive\s+--force|--force\s+--recursive))(\s|$)",
            visible,
        ) {
            let raw_args = paths[args.start()..args.end()].replace(['"', '\''], "");
            if [
                r"\s/(\s|$)",
                r"\s~(/?)(\s|$)",
                r"\s\$(HOME|\{HOME\})(/?)(\s|$)",
                r"\s/(Users|home)(/[^/\s]*)?/?(\s|$)",
                r"\s/(etc|var|usr|bin|sbin|opt|System|Library)(/|\s|$)",
            ]
            .iter()
            .any(|p| matches(p, &raw_args))
            {
                return Some(
                    "Recursive forced deletion of a root, home or system path is blocked. Inspect the target and use the specific intended directory.",
                );
            }
        }
    }
    None
}

fn strip_heredoc_bodies(command: &str) -> String {
    let heredoc = Regex::new(r#"<<(?P<dash>-?)\s*(['"]?)(?P<tag>[A-Za-z0-9_]+)['"]?"#)
        .expect("built-in heredoc pattern");
    let mut terminators = std::collections::VecDeque::new();
    let mut out = String::new();
    for line in command.split_inclusive('\n') {
        if let Some((expected, strip_tabs)) = terminators.front() {
            let candidate = line.trim_end_matches(['\r', '\n']);
            let candidate = if *strip_tabs {
                candidate.trim_start_matches('\t')
            } else {
                candidate
            };
            if candidate == expected {
                terminators.pop_front();
            }
            out.push('\n');
            continue;
        }
        out.push_str(line);
        let masked = mask_quoted_content(line);
        for captures in heredoc.captures_iter(line) {
            let start = captures.get(0).expect("full heredoc capture").start();
            if masked.as_bytes().get(start) != Some(&b'<')
                || start.checked_sub(1).and_then(|i| line.as_bytes().get(i)) == Some(&b'<')
                || line.as_bytes().get(start + 2) == Some(&b'<')
            {
                continue;
            }
            terminators.push_back((
                captures["tag"].to_string(),
                captures.name("dash").is_some_and(|m| m.as_str() == "-"),
            ));
        }
    }
    out
}

fn mask_quoted_content(command: &str) -> String {
    mask_content(command, true)
}

fn mask_content(command: &str, hide_quotes: bool) -> String {
    let mut bytes = command.as_bytes().to_vec();
    let original = command.as_bytes();
    let mut quote = None;
    let mut comment = false;
    let mut escaped = false;
    for (index, byte) in original.iter().copied().enumerate() {
        if comment {
            if byte == b'\n' {
                comment = false;
            } else {
                bytes[index] = b' ';
            }
            continue;
        }
        if escaped {
            if (quote.is_some() && hide_quotes)
                || (quote.is_none() && matches!(byte, b';' | b'&' | b'|' | b'\n'))
            {
                bytes[index] = b' ';
            }
            escaped = false;
            continue;
        }
        if byte == b'\\' && quote != Some(b'\'') {
            escaped = true;
            if quote.is_some() && hide_quotes {
                bytes[index] = b' ';
            }
            continue;
        }
        if let Some(active) = quote {
            if hide_quotes {
                bytes[index] = b' ';
            }
            if byte == active {
                quote = None;
            }
        } else if matches!(byte, b'\'' | b'"') {
            quote = Some(byte);
            if hide_quotes {
                bytes[index] = b' ';
            }
        } else if byte == b'#' && (index == 0 || original[index - 1].is_ascii_whitespace()) {
            bytes[index] = b' ';
            comment = true;
        }
    }
    String::from_utf8(bytes).expect("mask preserves UTF-8 outside quoted ranges")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn known_destructive_commands_are_blocked() {
        for command in [
            "git checkout .",
            "git checkout \".\"",
            "git checkout '.'",
            "git restore \".\"",
            "GIT_TRACE=1 git checkout \".\"",
            "env GIT_TRACE=1 git restore \".\"",
            "command git checkout \".\"",
            "echo y | git checkout \".\"",
            "git checkout . <<'EOF'\nnot command text\nEOF",
            "git clean -fd",
            "rm -rf /",
            "rm -rf ~/",
            "rm -rf /Users/foo",
            "rm --recursive --force /home/me",
            "rm --force --recursive /home/me",
            "sudo rm -Rf /etc",
            "rm -rf \"$HOME\"",
            "rm -rf '/home/some user'",
        ] {
            assert!(blocked_reason(command).is_some(), "{command}");
        }
    }
    #[test]
    fn text_data_and_ordinary_work_are_allowed() {
        for command in [
            "echo \"git checkout .\"",
            "printf \"%s\\n\" \"git restore .\"",
            "git commit -m \"repro: git checkout .\"",
            "git commit -m \"docs; git checkout .\"",
            "echo \"note && git restore .\"",
            "cat <<'EOF'\ngit checkout .\nrm -rf /\nEOF",
            "cat <<-EOF\n\tgit checkout .\n\tEOF",
            "cat <<123\ngit checkout .\nrm -rf /\n123",
            "rm -rf ./node_modules",
            "rm --force --force /",
            "rm --recursive --recursive /",
            "rm -rf ./build; echo /",
            "rm -rf ./build # /",
            "echo note\\; git clean -fd",
            "echo git clean -f",
            "# git checkout .\ncargo test",
            "git clean -nfd",
            "npm install",
            "pip install requests",
            "cat > docs/design.md",
            "git reset --hard HEAD",
            "git push --force-with-lease origin main",
        ] {
            assert!(blocked_reason(command).is_none(), "{command}");
        }
    }
    #[test]
    fn quoted_heredoc_marker_does_not_hide_a_later_command() {
        assert!(blocked_reason("echo '<<EOF'\ngit checkout .").is_some());
        assert!(blocked_reason("cat <<<EOF\ngit checkout .").is_some());
        assert!(blocked_reason("cat <<A <<B\ntext\nA\nmore text\nB\ngit checkout .").is_some());
    }
}
