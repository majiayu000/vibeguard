//! Limited recognition of destructive command spellings, not a shell sandbox.
pub fn blocked_reason(command: &str) -> Option<&'static str> {
    let command = match strip_heredoc_bodies(command) {
        Ok(command) => command,
        Err(reason) => return Some(reason),
    };
    let mut lexer = ShellLexer::new(&command);
    let mut words = Vec::new();
    let mut redirect_target = false;
    while let Some(token) = lexer.next_token().ok()? {
        match token {
            Token::Word(word) if !redirect_target => words.push(word),
            Token::Word(_) => redirect_target = false,
            Token::Redirect(_) => redirect_target = true,
            Token::Boundary => {
                if !redirect_target && let Some(reason) = simple_command_reason(&words) {
                    return Some(reason);
                }
                words.clear();
                redirect_target = false;
            }
        }
    }
    if redirect_target {
        None
    } else {
        simple_command_reason(&words)
    }
}

fn simple_command_reason(words: &[ShellWord<'_>]) -> Option<&'static str> {
    let mut args = words;
    if args.first().is_some_and(|word| word.raw == "env") {
        args = &args[1..];
    }
    while args.first().is_some_and(|word| {
        word.raw.split_once('=').is_some_and(|(name, _)| {
            let mut bytes = name.bytes();
            bytes
                .next()
                .is_some_and(|c| c.is_ascii_alphabetic() || c == b'_')
                && bytes.all(|c| c.is_ascii_alphanumeric() || c == b'_')
        })
    }) {
        args = &args[1..];
    }
    for wrapper in ["command", "sudo"] {
        if args.first().is_some_and(|word| word.raw == wrapper) {
            args = &args[1..];
        }
    }
    let (name, args) = args.split_first()?;
    if name.raw == "git" {
        let values: Vec<_> = args.iter().map(|word| word.value.as_str()).collect();
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
                "Forced git clean is blocked for this call, including explicit paths. This check cannot determine task-level authorization. If cleanup is already authorized, report this limitation to the user. Do not retry via another command/tool or disable the hook.",
            );
        }
    } else if matches!(name.raw, "rm" | "\\rm") && forced_recursive_rm(args) {
        let protected = "Recursive forced deletion of a root, home or system path is blocked. Inspect the target and use the specific intended directory.";
        if args.iter().any(protected_path) {
            return Some(protected);
        }
        #[cfg(windows)]
        for arg in args {
            if let Some(path) = windows_local_path(&arg.value) {
                match windows_long_path(&path) {
                    Ok(path) if windows_protected_path(&path) => return Some(protected),
                    Ok(_) => {}
                    Err(_) => {
                        return Some(
                            "Windows local path resolution failed. Recursive forced deletion is blocked because the target could not be inspected; check its existence and access permissions.",
                        );
                    }
                }
            }
        }
    }
    None
}

#[cfg(windows)]
fn windows_local_path(path: &str) -> Option<String> {
    let path = path.replace('\\', "/");
    let bytes = path.as_bytes();
    if bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1..3] == *b":/" {
        Some(path)
    } else if bytes.len() >= 2
        && bytes[0] == b'/'
        && bytes[1].is_ascii_alphabetic()
        && (bytes.len() == 2 || bytes[2] == b'/')
    {
        Some(format!(
            "{}:/{}",
            &path[1..2],
            path[2..].trim_start_matches('/')
        ))
    } else {
        // UNC remains lexical: do not introduce network I/O into this hook.
        None
    }
}

#[cfg(windows)]
fn windows_long_path(path: &str) -> std::io::Result<String> {
    use std::io::{Error, ErrorKind};
    use std::os::windows::ffi::OsStrExt;
    use std::path::PathBuf;
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetFullPathNameW(
            path: *const u16,
            size: u32,
            output: *mut u16,
            part: *mut *mut u16,
        ) -> u32;
        fn GetLongPathNameW(path: *const u16, output: *mut u16, size: u32) -> u32;
    }
    if path.contains('\0') {
        return Err(Error::new(ErrorKind::InvalidInput, "path contains NUL"));
    }
    let input: Vec<_> = path.encode_utf16().chain(Some(0)).collect();
    let mut output = vec![0u16; 32768];
    // SAFETY: input is NUL-terminated; output has the declared capacity. The
    // optional filename pointer is unused. Both APIs only inspect path names.
    let length = unsafe {
        GetFullPathNameW(
            input.as_ptr(),
            output.len() as u32,
            output.as_mut_ptr(),
            std::ptr::null_mut(),
        )
    } as usize;
    if length == 0 {
        return Err(Error::last_os_error());
    }
    if length >= output.len() {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            "Windows path is too long",
        ));
    }
    let normalized = String::from_utf16(&output[..length])
        .map_err(|error| Error::new(ErrorKind::InvalidData, error))?;
    let trailing_separator = normalized.ends_with(['/', '\\']);
    let mut prefix = PathBuf::from(normalized);
    let mut suffix = Vec::new();
    loop {
        let input: Vec<_> = prefix.as_os_str().encode_wide().chain(Some(0)).collect();
        // SAFETY: each prefix is NUL-terminated and output retains its capacity.
        let length =
            unsafe { GetLongPathNameW(input.as_ptr(), output.as_mut_ptr(), output.len() as u32) }
                as usize;
        if length >= output.len() {
            return Err(Error::new(
                ErrorKind::InvalidInput,
                "Windows path is too long",
            ));
        }
        if length > 0 {
            let mut path = PathBuf::from(
                String::from_utf16(&output[..length])
                    .map_err(|error| Error::new(ErrorKind::InvalidData, error))?,
            );
            path.extend(suffix.into_iter().rev());
            let mut path = path
                .into_os_string()
                .into_string()
                .map_err(|_| Error::new(ErrorKind::InvalidData, "Windows path is not UTF-8"))?;
            if trailing_separator && !path.ends_with(['/', '\\']) {
                path.push('/');
            }
            return Ok(path);
        }
        let error = Error::last_os_error();
        if error.kind() != ErrorKind::NotFound {
            return Err(error);
        }
        // Missing descendants cannot hide an existing protected alias above
        // them. Resolve the longest existing prefix, retaining their names.
        let Some(name) = prefix.file_name() else {
            return Err(error);
        };
        suffix.push(name.to_os_string());
        if !prefix.pop() {
            return Err(error);
        }
    }
}

struct ShellWord<'a> {
    raw: &'a str,
    value: String,
    home_expansion: bool,
    quoted: bool,
    dollar_quoted: bool,
}

enum Token<'a> {
    Word(ShellWord<'a>),
    Redirect(&'a str),
    Boundary,
}

struct ShellLexer<'a> {
    text: &'a str,
    chars: std::iter::Peekable<std::str::CharIndices<'a>>,
}

impl<'a> ShellLexer<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            text,
            chars: text.char_indices().peekable(),
        }
    }

    fn next_token(&mut self) -> Result<Option<Token<'a>>, ()> {
        while let Some(&(_, c)) = self.chars.peek() {
            if matches!(c, ' ' | '\t') {
                self.chars.next();
            } else if c == '#' {
                while self.chars.peek().is_some_and(|(_, c)| *c != '\n') {
                    self.chars.next();
                }
            } else {
                break;
            }
        }
        let Some(&(start, c)) = self.chars.peek() else {
            return Ok(None);
        };
        let rest = &self.text[start..];
        // An adjacent unquoted decimal fd belongs to the redirection, not argv.
        let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
        let offset = if rest[digits..].starts_with(['<', '>']) {
            digits
        } else {
            0
        };
        let operator = &rest[offset..];
        if let Some(op) = [
            "&>>", "<<<", "<<-", ">>", "<<", "<>", ">&", "<&", ">|", "&>", ">", "<",
        ]
        .into_iter()
        .find(|op| operator.starts_with(op))
        {
            for _ in 0..offset + op.len() {
                self.chars.next();
            }
            return Ok(Some(Token::Redirect(&operator[..op.len()])));
        }
        if matches!(c, ';' | '&' | '|' | '\n') {
            self.chars.next();
            return Ok(Some(Token::Boundary));
        }
        self.word().map(|word| Some(Token::Word(word))).ok_or(())
    }

    // Decode only simple words; retain source spelling and expansion origin.
    // Quoted words still occupy their command/argument position.
    fn word(&mut self) -> Option<ShellWord<'a>> {
        let start = self.chars.peek()?.0;
        let mut word = ShellWord {
            raw: "",
            value: String::new(),
            home_expansion: false,
            quoted: false,
            dollar_quoted: false,
        };
        let mut quote = None;
        let mut at_start = true;
        while let Some(&(index, c)) = self.chars.peek() {
            if quote.is_none() && matches!(c, ' ' | '\t' | '\n' | ';' | '&' | '|' | '<' | '>') {
                break;
            }
            self.chars.next();
            if c == '\\' && quote != Some('\'') {
                let (_, next) = self.chars.next()?;
                if next != '\n' {
                    if quote == Some('"') && !matches!(next, '$' | '`' | '"' | '\\') {
                        word.value.push('\\');
                    }
                    word.value.push(next);
                    word.quoted = true;
                    at_start = false;
                }
                continue;
            }
            if matches!(c, '\'' | '"') && (quote.is_none() || quote == Some(c)) {
                quote = if quote.is_none() { Some(c) } else { None };
                word.quoted = true;
                at_start = false;
                continue;
            }
            if c == '$'
                && quote.is_none()
                && self
                    .chars
                    .peek()
                    .is_some_and(|(_, next)| matches!(next, '\'' | '"'))
            {
                word.dollar_quoted = true;
            }
            if c == '$' && quote != Some('\'') && word.value.is_empty() {
                let rest = &self.text[index..];
                word.home_expansion |= rest.starts_with("${HOME}")
                    || rest.strip_prefix("$HOME").is_some_and(|tail| {
                        !tail.starts_with(|c: char| c.is_ascii_alphanumeric() || c == '_')
                    });
            }
            if c == '~' && quote.is_none() && at_start {
                // Bare tilde and the root user's home are supported symbolic
                // bases; other named-user expansions remain outside the grammar.
                let tail = &self.text[index + 1..];
                let tail = tail.strip_prefix("root").unwrap_or(tail);
                word.home_expansion |= tail.is_empty()
                    || tail.starts_with(|c: char| {
                        matches!(c, '/' | '<' | '>' | ';' | '&' | '|' | ' ' | '\t' | '\n')
                    });
            }
            word.value.push(c);
            at_start = false;
        }
        if quote.is_some() {
            return None;
        }
        let end = self
            .chars
            .peek()
            .map_or(self.text.len(), |(index, _)| *index);
        word.raw = &self.text[start..end];
        Some(word)
    }
}

fn protected_path(word: &ShellWord) -> bool {
    if word.home_expansion {
        for prefix in ["~root", "~", "$HOME", "${HOME}"] {
            if let Some(tail) = word.value.strip_prefix(prefix)
                && (tail.is_empty() || tail.starts_with('/'))
            {
                // An empty tail targets home. Remaining leading parents leave
                // this symbolic base and may descend into a protected path;
                // reject them without resolving HOME or looking up users.
                return normalized_components(tail.trim_start_matches('/'))
                    .first()
                    .is_none_or(|part| *part == "..");
            }
        }
    }
    if cfg!(windows) && windows_protected_path(&word.value) {
        return true;
    }
    if !word.value.starts_with('/') {
        return false;
    }
    let parts = normalized_components(&word.value);
    parts.is_empty()
        || parts == ["root"]
        || (matches!(parts.first(), Some(&"Users" | &"home")) && parts.len() <= 2)
        || matches!(
            parts.first(),
            Some(&"etc" | &"var" | &"usr" | &"bin" | &"sbin" | &"opt" | &"System" | &"Library")
        )
        || (cfg!(target_os = "macos")
            && parts.first() == Some(&"private")
            && matches!(parts.get(1), Some(&"etc" | &"var")))
}

fn windows_protected_path(path: &str) -> bool {
    // Inspect the parsed Bash word, not its raw spelling: unquoted backslashes
    // have already been consumed by Bash quoting rules.
    let path = path.replace('\\', "/").to_ascii_lowercase();
    let bytes = path.as_bytes();
    let drive_path = if bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1..3] == *b":/"
    {
        &path[2..]
    } else if bytes.len() >= 2
        && bytes[0] == b'/'
        && bytes[1].is_ascii_alphabetic()
        && (bytes.len() == 2 || bytes[2] == b'/')
    {
        // Git Bash's /c and /c/... drive mount spelling.
        &path[2..]
    } else if let Some(unc) = path.strip_prefix("//") {
        // The server/share pair is the volume root, not normal path components.
        let mut parts = unc.splitn(3, '/');
        if parts.next().is_none_or(str::is_empty) || parts.next().is_none_or(str::is_empty) {
            return false;
        }
        return windows_protected_path(&format!("C:/{}", parts.next().unwrap_or("")));
    } else if path.starts_with('/') {
        &path
    } else {
        return false;
    };
    // Resolve dot navigation before comparing Win32 component spellings. An
    // all-dot/space component must still occupy one level when followed by `..`.
    let mut parts = normalized_components(drive_path)
        .into_iter()
        .map(|part| part.trim_end_matches(['.', ' ']))
        .collect::<Vec<_>>();
    // Without a trailing separator, Win32 strips all terminal dots/spaces.
    // A resulting empty final component denotes the containing directory.
    if !drive_path.ends_with('/') && parts.last() == Some(&"") {
        parts.pop();
    }
    parts.is_empty()
        || (parts.first() == Some(&"users") && parts.len() <= 2)
        || matches!(
            parts.first(),
            Some(&"windows" | &"program files" | &"program files (x86)" | &"programdata")
        )
}

fn normalized_components(path: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." if parts.last().is_some_and(|part| *part != "..") => {
                parts.pop();
            }
            ".." if path.starts_with('/') => {}
            part => parts.push(part),
        }
    }
    parts
}

fn forced_recursive_rm(args: &[ShellWord]) -> bool {
    let mut recursive = false;
    let mut force = false;
    for arg in args {
        match arg.value.as_str() {
            "--" => break,
            "--recursive" => recursive = true,
            "--force" => force = true,
            arg if arg.starts_with('-') && !arg.starts_with("--") => {
                recursive |= arg.contains(['r', 'R']);
                force |= arg.contains('f');
            }
            _ => {}
        }
    }
    recursive && force
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

fn strip_heredoc_bodies(command: &str) -> Result<String, &'static str> {
    let mut terminators = std::collections::VecDeque::new();
    let mut out = String::new();
    let mut header = String::new();
    let mut header_mask = ContentMask::default();
    let mut body_line = String::new();
    for line in command.split_inclusive('\n') {
        if let Some((expected, strip_tabs, quoted)) = terminators.front() {
            // Bash treats CR as data even in CRLF input. Only LF ends the line.
            let candidate = line.strip_suffix('\n').unwrap_or(line);
            // Unquoted heredocs join escaped newlines before testing the
            // delimiter. Quotes in body data do not alter this behavior.
            if !quoted
                && line.ends_with('\n')
                && candidate.bytes().rev().take_while(|b| *b == b'\\').count() % 2 == 1
            {
                body_line.push_str(&candidate[..candidate.len() - 1]);
                out.push('\n');
                continue;
            }
            body_line.push_str(candidate);
            let candidate = if *strip_tabs {
                body_line.trim_start_matches('\t')
            } else {
                &body_line
            };
            if candidate == expected {
                terminators.pop_front();
            }
            body_line.clear();
            out.push('\n');
            continue;
        }
        // Carry lexical state forward once per byte, rather than remasking
        // the growing prefix at every continued physical line.
        header.push_str(line);
        let mut last = None;
        for byte in line.bytes() {
            last = Some(header_mask.mask_byte(byte, true));
        }
        if line.ends_with('\n') && last != Some(b'\n') {
            continue;
        }
        let normalized = strip_line_continuations(&header);
        out.push_str(&normalized);
        let mut lexer = ShellLexer::new(&normalized);
        let mut heredoc = None;
        while let Ok(Some(token)) = lexer.next_token() {
            match token {
                Token::Redirect(op @ ("<<" | "<<-")) => heredoc = Some(op == "<<-"),
                Token::Word(word) => {
                    if let Some(strip_tabs) = heredoc.take() {
                        // ANSI-C escapes and locale translation need shell evaluation;
                        // never use a guessed terminator to hide the remaining commands.
                        if word.dollar_quoted {
                            return Err("Unsupported dollar-quoted heredoc delimiter");
                        }
                        // The entire word is the delimiter after quote removal;
                        // never truncate it to an alphanumeric prefix.
                        terminators.push_back((word.value, strip_tabs, word.quoted));
                    }
                }
                _ => heredoc = None,
            }
        }
        header.clear();
        header_mask = ContentMask::default();
    }
    out.push_str(&strip_line_continuations(&header));
    Ok(out)
}

fn strip_line_continuations(command: &str) -> String {
    let mut mask = ContentMask::default();
    let mut bytes = command.bytes().peekable();
    let mut out = Vec::with_capacity(command.len());
    while let Some(byte) = bytes.next() {
        // Double quotes also remove these pairs, before HOME source detection.
        // Comments, single quotes and escaped backslashes retain literal data.
        if byte == b'\\'
            && bytes.peek() == Some(&b'\n')
            && !mask.comment
            && !mask.escaped
            && mask.quote != Some(b'\'')
        {
            bytes.next();
        } else {
            mask.mask_byte(byte, false);
            out.push(byte);
        }
    }
    String::from_utf8(out).expect("continuation removal preserves UTF-8")
}

struct ContentMask {
    quote: Option<u8>,
    comment: bool,
    escaped: bool,
    word_start: bool,
}

impl Default for ContentMask {
    fn default() -> Self {
        Self {
            quote: None,
            comment: false,
            escaped: false,
            word_start: true,
        }
    }
}

impl ContentMask {
    fn mask_byte(&mut self, byte: u8, hide_quotes: bool) -> u8 {
        if self.comment {
            if byte == b'\n' {
                self.comment = false;
                self.word_start = true;
                return byte;
            }
            return b' ';
        }
        if self.escaped {
            self.escaped = false;
            if byte != b'\n' {
                self.word_start = false;
            }
            return if (self.quote.is_some() && hide_quotes)
                || (self.quote.is_none() && matches!(byte, b';' | b'&' | b'|' | b'\n'))
            {
                b' '
            } else {
                byte
            };
        }
        if byte == b'\\' && self.quote != Some(b'\'') {
            self.escaped = true;
            return if self.quote.is_some() && hide_quotes {
                b' '
            } else {
                byte
            };
        }
        if let Some(active) = self.quote {
            if byte == active {
                self.quote = None;
            }
            return if hide_quotes { b' ' } else { byte };
        } else if matches!(byte, b'\'' | b'"') {
            self.quote = Some(byte);
            self.word_start = false;
            return if hide_quotes { b' ' } else { byte };
        } else if byte == b'#' && self.word_start {
            self.comment = true;
            return b' ';
        } else {
            self.word_start = byte.is_ascii_whitespace()
                || matches!(byte, b';' | b'&' | b'|' | b'(' | b')' | b'<' | b'>');
        }
        byte
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn windows_volume_and_system_paths_are_recognized() {
        for path in [
            "C:/",
            "c:/Windows/System32",
            r"C:\WINDOWS",
            "/c",
            "/C/Windows",
            "D:/Users/name",
            r"D:\Users\name",
            "c:/users",
            "/d/Users/name/Downloads/..",
            "C:/tmp/../Windows",
            "C:/Program Files/app",
            "C:/Program Files (x86)",
            "C:/ProgramData",
            r"C:\Windows.\System32",
            "C:/Windows /System32",
            "/c/Users. /name",
            "C:/Program Files.../app",
            "//server/share/ProgramData. /app",
            "C:/tmp. /../Windows...",
            "C:/Windows/.../../System32",
            "C:/Windows/   /../System32",
            "//server/share/Windows/.../../System32",
            "C:/...",
            "C:/   ",
            "C:/Users/name/...",
            "C:/Users/name/   ",
            r"\\server\share",
            "//server/share/Users/name",
            "//server/share/Windows/System32",
            "C:/..",
            "/c/../",
        ] {
            assert!(super::windows_protected_path(path), "{path}");
        }
        for path in [
            "C:/tmp/build",
            "C:/Users/name/cache",
            "/c/Users/name/project",
            "C:/Windows/../tmp",
            "C:/Windows. /../tmp",
            "C:/Windows/.../../../tmp",
            "C:/Users/name/.../../cache",
            "C:/.../",
            "C:/   /",
            "C:/Users/name/.../",
            "C:/Users/name/   /",
            "C:/.../...",
            "C:/Users. /name/cache",
            "C:Windows",
            "./Windows",
            "Windows",
            "/cache/build",
            "//server/share/projects/build",
        ] {
            assert!(!super::windows_protected_path(path), "{path}");
        }
    }

    #[cfg(windows)]
    #[test]
    fn windows_rm_checks_use_bash_quoting_and_preserve_safe_arguments() {
        for command in [
            "rm -rf /c/Windows",
            r"rm -rf 'C:\Users\name'",
            "rm -r -f C:/Windows",
            "rm -rf '/c/Program Files'",
            "rm -rf //server/share",
            r"rm -rf 'C:\Windows.\System32'",
            "rm -rf '/c/Users. /name'",
        ] {
            assert!(super::blocked_reason(command).is_some(), "{command}");
        }
        for command in [
            "rm -rf C:/Users/name/cache",
            "rm -rf 'C:/Users. /name/cache'",
            r"rm -rf C:\Users\name",
            "echo 'rm -rf C:/Windows'",
            "rm -rf ./build > C:/Windows",
            "rm -r C:/Windows",
            "rm -rf C:Windows",
        ] {
            assert!(super::blocked_reason(command).is_none(), "{command}");
        }
    }

    use super::*;

    #[test]
    fn simple_command_boundaries_preserve_decisions() {
        // All commands are inert classifier inputs, including the policy denials.
        for (command, denied) in [
            ("git checkout .", true),
            ("git restore -- .", true),
            ("git clean -fd", true),
            ("rm -rf /etc", true),
            ("git clean -nfd", false),
            ("rm -rf ./build", false),
            ("'echo' git clean -fd", false),
            ("'/bin/printf' '%s\\n' rm -rf /etc", false),
        ] {
            for prefix in ["", "git\n", "rm\n", "env\n", "git\n\n", "echo ok;\n"] {
                let input = format!("{prefix}{command}");
                assert_eq!(blocked_reason(&input).is_some(), denied, "{input:?}");
            }
        }
    }

    #[test]
    fn redirections_preserve_argv_at_every_word_boundary() {
        let cases: &[(&[&str], bool)] = &[
            (&["git", "checkout", "."], true),
            (&["git", "restore", "--", "."], true),
            (&["git", "clean", "-fd"], true),
            (&["git", "clean", "-f", "-n"], false),
            (&["git", "clean", "-f", "-e", "-n"], true),
            (&["git", "clean", "-f", "--no-force"], false),
            (&["rm", "-rf", "/etc"], true),
            (&["rm", "-rf", "./build"], false),
            (
                &[
                    "env",
                    "X='a b'",
                    "command",
                    "sudo",
                    "rm",
                    "-rf",
                    "\"$HOME\"",
                ],
                true,
            ),
            (&["'echo'", "git", "clean", "-fd"], false),
        ];
        for &(words, denied) in cases {
            for redirect in [
                ">out",
                "2>out",
                "2>>out",
                "0<in",
                "2>&1",
                "0<&3",
                ">|out",
                "&>out",
                "&>>out",
                "3<>file",
                ">&2",
                "2>&-",
                ">'-n'",
                "2>'--no-force'",
                ">'; git clean -fd'",
            ] {
                for index in 0..=words.len() {
                    let mut tokens = words.to_vec();
                    tokens.insert(index, redirect);
                    let input = tokens.join(" ");
                    assert_eq!(blocked_reason(&input).is_some(), denied, "{input:?}");
                }
            }
        }
        // A quoted, escaped, or separated number remains an ordinary argument.
        for input in [
            "git checkout . '2'>out",
            "git checkout . \\2>out",
            "git checkout . 2 >out",
        ] {
            assert!(blocked_reason(input).is_none(), "{input:?}");
        }
    }

    #[test]
    fn heredocs_use_whole_delimiter_words_and_unescaped_operators() {
        for (delimiter, terminator) in [
            ("EOF-END", "EOF-END"),
            ("'EOF-END'", "EOF-END"),
            ("E'O'F-END", "EOF-END"),
            ("\\EOF-END", "EOF-END"),
            ("'EOF END'", "EOF END"),
            ("'名前'", "名前"),
            ("''", ""),
        ] {
            let body = format!("cat <<{delimiter}\ngit clean -fd\n{terminator}\n");
            assert!(blocked_reason(&body).is_none(), "{body:?}");
            let later_command = format!("{body}git clean -fd");
            assert!(
                blocked_reason(&later_command).is_some(),
                "{later_command:?}"
            );
        }
        for input in [
            "echo \\<<EOF\ngit clean -fd",
            "echo \\<\\<EOF\ngit clean -fd",
            "echo '<<EOF'\ngit clean -fd",
            "cat <<<EOF\ngit clean -fd",
        ] {
            assert!(blocked_reason(input).is_some(), "{input:?}");
        }
    }

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
    fn rm_options_use_parsed_words_and_stop_at_double_dash() {
        for command in [
            "rm -r -f /",
            "rm -f -r /",
            "rm -r --force /",
            "rm --recursive -f /",
            "rm -f --recursive /",
            "rm --force -R /",
            "rm '-r' '-f' /",
            "sudo rm -r -f /",
            "command rm -f -r /",
            "env IGNORE=1 rm -r --force /",
            "rm -r / --force",
            "rm -r -f -- /",
        ] {
            assert!(blocked_reason(command).is_some(), "{command}");
        }
        for command in [
            "rm -r /",
            "rm -f /",
            "rm -- -rf /",
            "rm -r -- -f /",
            "rm -f -- --recursive /",
            "rm -r / > '-f'",
            "rm -f / > '--recursive'",
            "rm -r -f ./build",
        ] {
            assert!(blocked_reason(command).is_none(), "{command}");
        }
    }

    #[test]
    fn rm_protected_paths_are_normalized_lexically() {
        for command in [
            "rm -rf /.",
            "rm -rf /..",
            "rm -rf //",
            "rm -rf ///",
            "rm -rf /./",
            "rm -rf /home/user/..",
            "rm -rf /Users/foo/..",
            "rm -rf /tmp/../etc",
            "rm -rf /tmp/..//Users/foo/./",
            "rm -rf /tmp/../var/log",
            "rm -rf \"$HOME/..\"",
            "rm -rf ~/..",
            "rm -rf \"${HOME}/./\"",
            "rm -rf \"$HOME/cache/..\"",
            "rm -rf ~/cache/../..",
            "rm -rf ~/../..",
        ] {
            assert!(blocked_reason(command).is_some(), "{command}");
        }
        for command in [
            "rm -rf /tmp//build/./",
            "rm -rf /etc/../tmp/build",
            "rm -rf /Users/foo/cache",
            "rm -rf /home/user/cache",
            "rm -rf ~/cache",
            "rm -rf \"$HOME/cache\"",
            "rm -rf \"${HOME}/cache/../build\"",
            "rm -rf '$HOME/..'",
            "rm -rf '${HOME}/..'",
            "rm -rf '~/..'",
            r"rm -rf \$HOME/..",
            "rm -rf '$HOME/'\"$HOME/..\"",
            "rm -rf '~/'\"$HOME/..\"",
        ] {
            assert!(blocked_reason(command).is_none(), "{command}");
        }
        if cfg!(target_os = "macos") {
            for command in [
                "rm -rf /private/etc",
                "rm -rf /private/var",
                "rm -rf /private/etc/hosts",
                "rm -rf /tmp/../private/var/log",
            ] {
                assert!(blocked_reason(command).is_some(), "{command}");
            }
        } else {
            assert!(blocked_reason("rm -rf /private/etc").is_none());
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
    fn unsupported_dollar_quoted_heredoc_delimiters_are_rejected() {
        for command in [
            "cat <<$'EOF'\ntext\nEOF\ngit clean -fd",
            "cat <<-$'EOF'\n\ttext\n\tEOF\ngit clean -fd",
            "cat <<$'E\\x4fF'\ntext\nEOF\ngit clean -fd",
            "cat <<E$'OF'\ntext\nEOF\ngit clean -fd",
            "cat <<$\"EOF\"\ntext\nEOF\ngit clean -fd",
            "cat <<$'EOF'\nordinary body\nEOF\n",
        ] {
            assert!(blocked_reason(command).is_some(), "{command:?}");
        }
        for command in [
            "cat <<'$EOF'\ngit clean -fd\n$EOF\n",
            "cat <<\"$'EOF'\"\ngit clean -fd\n$'EOF'\n",
            "echo \"$'EOF'\"",
        ] {
            assert!(blocked_reason(command).is_none(), "{command:?}");
        }
    }
    #[test]
    fn quoted_heredoc_marker_does_not_hide_a_later_command() {
        assert!(blocked_reason("echo '<<EOF'\ngit checkout .").is_some());
        assert!(blocked_reason("cat <<<EOF\ngit checkout .").is_some());
        assert!(blocked_reason("cat <<A <<B\ntext\nA\nmore text\nB\ngit checkout .").is_some());
    }
}
