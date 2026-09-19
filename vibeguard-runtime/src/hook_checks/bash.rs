//! Limited recognition of destructive command spellings, not a shell sandbox.
use regex::Regex;

fn matches(pattern: &str, text: &str) -> bool {
    Regex::new(pattern)
        .expect("built-in command pattern")
        .is_match(text)
}

pub fn blocked_reason(command: &str) -> Option<&'static str> {
    let command = strip_heredoc_bodies(command);
    let masked = mask_quoted_content(&command);
    let paths = mask_content(&command, false);
    // Match actual command positions. Quoted text and comments are blanked,
    // preserving byte offsets so path arguments can be inspected separately.
    let starts = Regex::new(
        r"(?m)(^|[;&|\n])\s*(?:env\s+)?(?:[A-Za-z_][A-Za-z0-9_]*=[^\s;&|]*\s+)*(?:command\s+)?(?:sudo\s+)?(?P<name>\\?rm|git)\s+?(?P<args>[^;&|\n]*)",
    ).expect("built-in command position pattern");
    for captures in starts.captures_iter(&masked) {
        let args = captures.name("args").expect("args capture");
        let visible = args.as_str().trim_start();
        let Some(words) = shell_words(&paths[args.start()..args.end()]) else {
            continue;
        };
        if &captures["name"] == "git" {
            let values: Vec<_> = words.iter().map(|word| word.value.as_str()).collect();
            let target = if values.get(1) == Some(&"--") { 2 } else { 1 };
            if matches!(values.first(), Some(&"checkout" | &"restore"))
                && values.get(target) == Some(&".")
                && values.len() == target + 1
            {
                return Some(
                    "Bulk git checkout/restore of the working tree is blocked. Inspect the diff and target the intended files.",
                );
            }
            if values.first() == Some(&"clean") && forced_git_clean(&values[1..]) {
                return Some(
                    "Forced git clean is blocked. Preview with git clean -n and select the files to remove.",
                );
            }
        } else if matches(
            r"^((-[A-Za-z]*([rR][A-Za-z]*f|f[A-Za-z]*[rR]))|(--recursive\s+--force|--force\s+--recursive))(\s|$)",
            visible,
        ) && words.iter().any(protected_path)
        {
            return Some(
                "Recursive forced deletion of a root, home or system path is blocked. Inspect the target and use the specific intended directory.",
            );
        }
    }
    None
}

struct ShellWord {
    value: String,
    home_expansion: bool,
}

// Only decode simple words; never evaluate variables or substitutions. Track
// HOME/tilde at the source position so quoted literals cannot become expansions.
fn shell_words(text: &str) -> Option<Vec<ShellWord>> {
    let mut words = Vec::new();
    let mut chars = text.char_indices().peekable();
    let mut redirect_target = false;
    while chars.peek().is_some() {
        while chars.peek().is_some_and(|(_, c)| c.is_ascii_whitespace()) {
            chars.next();
        }
        if chars.peek().is_none() {
            break;
        }
        if chars.peek().is_some_and(|(_, c)| matches!(c, '<' | '>')) {
            // Redirection operands are shell data, never command options.
            while chars.peek().is_some_and(|(_, c)| matches!(c, '<' | '>')) {
                chars.next();
            }
            redirect_target = true;
            continue;
        }
        let mut word = ShellWord {
            value: String::new(),
            home_expansion: false,
        };
        let mut quote = None;
        let mut at_start = true;
        while let Some(&(index, c)) = chars.peek() {
            if quote.is_none() && matches!(c, '<' | '>') {
                break;
            }
            chars.next();
            if quote.is_none() && c.is_ascii_whitespace() {
                break;
            }
            if c == '\\' && quote != Some('\'') {
                let (_, next) = chars.next()?;
                if next != '\n' {
                    if quote == Some('"') && !matches!(next, '$' | '`' | '"' | '\\') {
                        word.value.push('\\');
                    }
                    word.value.push(next);
                    at_start = false;
                }
                continue;
            }
            if matches!(c, '\'' | '"') && (quote.is_none() || quote == Some(c)) {
                quote = if quote.is_none() { Some(c) } else { None };
                at_start = false;
                continue;
            }
            if c == '$' && quote != Some('\'') {
                let rest = &text[index..];
                word.home_expansion |= rest.starts_with("${HOME}")
                    || rest.strip_prefix("$HOME").is_some_and(|tail| {
                        !tail.starts_with(|c: char| c.is_ascii_alphanumeric() || c == '_')
                    });
            }
            if c == '~' && quote.is_none() && at_start {
                word.home_expansion |= chars
                    .peek()
                    .is_none_or(|(_, c)| *c == '/' || c.is_ascii_whitespace());
            }
            word.value.push(c);
            at_start = false;
        }
        if quote.is_some() {
            return None;
        }
        if redirect_target {
            redirect_target = false;
        } else {
            words.push(word);
        }
    }
    Some(words)
}

fn protected_path(word: &ShellWord) -> bool {
    let path = word.value.strip_suffix('/').unwrap_or(&word.value);
    if word.home_expansion && matches!(path, "~" | "$HOME" | "${HOME}") {
        return true;
    }
    word.value == "/"
        || matches(r"^/(Users|home)(/[^/]*)?$", path)
        || matches(r"^/(etc|var|usr|bin|sbin|opt|System|Library)(/|$)", path)
}

fn forced_git_clean(args: &[&str]) -> bool {
    let mut force = false;
    let mut dry_run = false;
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        match *arg {
            "--" => break,
            "--force" => force = true,
            "--no-force" => force = false,
            "--dry-run" => dry_run = true,
            "--no-dry-run" => dry_run = false,
            "--exclude" => {
                args.next();
            }
            arg if arg.starts_with('-') && !arg.starts_with("--") => {
                let mut flags = arg[1..].chars();
                while let Some(flag) = flags.next() {
                    match flag {
                        'f' => force = true,
                        'n' => dry_run = true,
                        'e' => {
                            if flags.next().is_none() {
                                args.next();
                            }
                            break;
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    force && !dry_run
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
    let mut word_start = true;
    for (index, byte) in original.iter().copied().enumerate() {
        if comment {
            if byte == b'\n' {
                comment = false;
                word_start = true;
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
            if byte != b'\n' {
                word_start = false;
            }
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
            word_start = false;
            if hide_quotes {
                bytes[index] = b' ';
            }
        } else if byte == b'#' && word_start {
            bytes[index] = b' ';
            comment = true;
        } else {
            word_start = byte.is_ascii_whitespace()
                || matches!(byte, b';' | b'&' | b'|' | b'(' | b')' | b'<' | b'>');
        }
    }
    String::from_utf8(bytes).expect("mask preserves UTF-8 outside quoted ranges")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shell_literals_and_comment_boundaries_are_preserved() {
        for command in [
            "rm -rf '$HOME'",
            "rm -rf '${HOME}'",
            "rm -rf '~'",
            "rm -rf \"~\"",
            r"rm -rf \$HOME",
            r#"rm -rf "\$HOME""#,
            "rm -rf '名前 $HOME'",
            "rm -rf 'a /etc'",
            "rm -rf ./build > '/etc'",
            "rm -rf '$HO'\"ME\"",
            "rm -rf \"$HO\"\"ME\"",
            "rm -rf '~'/",
            "echo ok;# note; git clean -fd",
            "echo ok&&# note; git clean -fd",
        ] {
            assert!(blocked_reason(command).is_none(), "{command}");
        }
        for command in [
            "rm -rf $HOME",
            "rm -rf ${HOME}/",
            "rm -rf \"${HOME}\"",
            "rm -rf ~",
            "rm -rf '/etc'",
            "rm -rf '/home/some user'",
            "echo ok;# note\ngit clean -fd",
            "echo 名前; git clean -fd",
        ] {
            assert!(blocked_reason(command).is_some(), "{command}");
        }
    }

    #[test]
    fn git_clean_options_respect_order_boundaries_and_values() {
        for command in [
            "git clean -fd -- -n",
            "git clean -fd -- --dry-run",
            "git clean --force -d",
            "git clean -d --force",
            "git clean --no-force -fd",
            "git clean -nf --no-dry-run",
            "git clean -f -e -n",
            "git clean -f --exclude --dry-run",
            "git clean -f --exclude=-n",
            "git clean -fe-n",
            "git clean '-fd'",
            "git clean -f 'a -n'",
            "git clean -f -- -n --no-force",
            "git clean -f > '-n'",
            "git clean -f > '--no-force'",
            "git clean -f >'-n'",
            "git clean -f 2> '-n'",
            "git clean -f < '-n'",
            "git clean -f >>'-n'",
            "git 'clean' -f",
            "git  clean -f",
        ] {
            assert!(blocked_reason(command).is_some(), "{command}");
        }
        for command in [
            "git clean -nf",
            "git clean -fn",
            "git clean -f --dry-run",
            "git clean -f --no-force",
            "git clean -- -f",
            "git clean -n --force",
            "git clean --dry-run --no-dry-run -fn",
            "git clean -f -e cache -n",
            "git clean -f --exclude=cache -n",
            "git clean -f >out -n",
        ] {
            assert!(blocked_reason(command).is_none(), "{command}");
        }
    }
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
