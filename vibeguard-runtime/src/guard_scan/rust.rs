use super::shared::{Finding, Result, ScanContext, ScanResult, is_rust_test_path};
use regex::Regex;

pub(super) fn unwrap(context: &ScanContext) -> Result<ScanResult> {
    let unwrap_call = Regex::new(r"\.\s*(?:unwrap|expect)\s*\(")?;
    let mut findings = Vec::new();
    for path in context
        .files_with_extensions(&["rs"])
        .into_iter()
        .filter(|path| !is_rust_test_path(path))
    {
        let content = context.read(&path)?;
        let masked = mask_rust_non_code(&content);
        let test_lines = test_scope_lines(&masked);
        let previous_call_scopes = match context.previous_content(&path)? {
            Some(previous) => {
                let previous_masked = mask_rust_non_code(&previous);
                let previous_test_lines = test_scope_lines(&previous_masked);
                let mut scopes = std::collections::BTreeMap::<String, (usize, usize)>::new();
                for site in unwrap_call_sites(&previous_masked, &unwrap_call) {
                    let (test_count, production_count) = scopes.entry(site.key).or_default();
                    if previous_test_lines.contains(&site.line) {
                        *test_count += 1;
                    } else {
                        *production_count += 1;
                    }
                }
                scopes
            }
            None => std::collections::BTreeMap::new(),
        };
        let mut current = Vec::new();
        let mut current_occurrences = std::collections::BTreeMap::<String, usize>::new();
        for site in unwrap_call_sites(&masked, &unwrap_call) {
            if test_lines.contains(&site.line) {
                continue;
            }
            let occurrence = current_occurrences.entry(site.key.clone()).or_default();
            let was_test_scoped = previous_call_scopes.get(&site.key).is_some_and(
                |(test_count, production_count)| {
                    *occurrence >= *production_count
                        && *occurrence < *production_count + *test_count
                },
            );
            *occurrence += 1;
            if !was_test_scoped && !context.allows_line(&path, site.line) {
                continue;
            }
            current.push(Finding {
                rule: "RS-03",
                path: path.clone(),
                line: site.line,
                message: "[review] [this-edit] OBSERVATION: unwrap()/expect() in production code"
                    .to_string(),
            });
        }
        findings.extend(context.keep_unsuppressed(&content, current));
    }
    Ok(ScanResult::new(
        findings,
        "No unwrap()/expect() in production code.",
        "Found {count} unwrap()/expect() call(s) in production code.",
        &[
            "SCOPE: this-line only — do not fix other unwrap calls, add error types, or change function signatures",
            "ACTION: REVIEW",
        ],
    ))
}

pub(super) fn nested_locks(context: &ScanContext) -> Result<ScanResult> {
    let function = Regex::new(r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)")?;
    let lock = Regex::new(r"\.(?:read|write|lock)\s*\(")?;
    let immediate_value = Regex::new(
        r"\.(?:read|write|lock)\s*\([^)]*\)\.(?:clone|to_owned|to_string|len|is_empty|contains)\(",
    )?;
    let drop_call = Regex::new(r"\bdrop\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)")?;
    let release = Regex::new(r"(?:\bdrop\s*\(|})")?;
    let mut findings = Vec::new();
    for path in context
        .files_with_extensions(&["rs"])
        .into_iter()
        .filter(|path| !is_rust_test_path(path))
    {
        let content = context.read(&path)?;
        let masked = mask_rust_non_code(&content);
        let mut function_name = None;
        let mut function_line = 0;
        let mut function_depth = 0isize;
        let mut function_has_body = false;
        let mut depth = 0isize;
        let mut lock_depths: Vec<(isize, Option<String>)> = Vec::new();
        let mut max_active = 0usize;
        let mut total = 0usize;
        let mut statement_prefix = String::new();
        let mut current = Vec::new();
        let masked_lines = masked.lines().collect::<Vec<_>>();
        for (index, line) in masked_lines.iter().enumerate() {
            let line_number = index + 1;
            if function_name.is_none()
                && let Some(captures) = function.captures(line)
            {
                function_name = Some(captures[1].to_string());
                function_line = line_number;
                function_depth = depth;
                function_has_body = false;
                lock_depths.clear();
                max_active = 0;
                total = 0;
            }
            let lock_positions = lock
                .find_iter(line)
                .map(|found| found.start())
                .collect::<Vec<_>>();
            let track_locks = !(lock_positions.len() == 1 && immediate_value.is_match(line));
            let drops = drop_call
                .captures_iter(line)
                .filter_map(|captures| {
                    Some((
                        captures.get(0)?.start(),
                        captures.get(1)?.as_str().to_string(),
                    ))
                })
                .collect::<Vec<_>>();
            let mut next_lock = 0usize;
            let mut next_drop = 0usize;
            for (position, character) in line.char_indices() {
                while track_locks && lock_positions.get(next_lock) == Some(&position) {
                    total += 1;
                    lock_depths.push((depth, lock_binding_name(&statement_prefix, line, position)));
                    max_active = max_active.max(lock_depths.len());
                    next_lock += 1;
                }
                while drops
                    .get(next_drop)
                    .is_some_and(|(start, _)| *start == position)
                {
                    let name = &drops[next_drop].1;
                    lock_depths.retain(|(_, binding)| binding.as_deref() != Some(name));
                    next_drop += 1;
                }
                match character {
                    '{' => {
                        function_has_body |= function_name.is_some() && depth == function_depth;
                        depth += 1;
                    }
                    '}' => {
                        lock_depths.retain(|(lock_depth, _)| *lock_depth < depth);
                        depth = depth.saturating_sub(1);
                    }
                    ';' => lock_depths.retain(|(_, binding)| binding.is_some()),
                    _ => {}
                }
            }
            if let Some(position) = line.rfind([';', '{', '}']) {
                statement_prefix.clear();
                statement_prefix.push_str(&line[position + 1..]);
            } else {
                statement_prefix.push_str(line);
                statement_prefix.push('\n');
            }
            if let Some(name) = function_name.as_deref()
                && depth <= function_depth
                && line.contains('}')
            {
                let changed_lock = (function_line..=line_number).any(|candidate| {
                    context.allows_line(&path, candidate)
                        && masked_lines
                            .get(candidate.saturating_sub(1))
                            .is_some_and(|candidate_line| lock.is_match(candidate_line))
                });
                let deleted_release =
                    context.has_deleted_between(&path, function_line, line_number, &release);
                if max_active > 1 && (changed_lock || deleted_release) {
                    current.push(Finding {
                        rule: "RS-01",
                        path: path.clone(),
                        line: function_line,
                        message: format!(
                            "fn {name} — {max_active} concurrent lock acquisitions (of {total} total)"
                        ),
                    });
                }
                function_name = None;
            }
            if function_name.is_some() && !function_has_body && line.contains(';') {
                function_name = None;
            }
        }
        findings.extend(context.keep_unsuppressed(&content, current));
    }
    Ok(ScanResult::new(
        findings,
        "No nested lock patterns detected.",
        "Found {count} potential nested lock pattern(s).",
        &["Repair: unify lock acquisition order or reduce the lock scope."],
    ))
}

pub(super) fn taste_invariants(context: &ScanContext) -> Result<ScanResult> {
    let ansi = Regex::new(r"\\(?:x1b|033|e)\[")?;
    let panic = Regex::new(r#"panic!\s*\(\s*(?:""\s*)?\)"#)?;
    let function = Regex::new(r"\basync\s+fn\s+")?;
    let unwrap_call = Regex::new(r"\.\s*(?:unwrap|expect)\s*\(")?;
    let mut findings = Vec::new();
    for path in context
        .files_with_extensions(&["rs"])
        .into_iter()
        .filter(|path| !is_rust_test_path(path))
    {
        let content = context.read(&path)?;
        let masked = mask_rust_non_code(&content);
        let mut async_depth = None;
        let mut pending_async = false;
        let mut depth = 0isize;
        let mut current = Vec::new();
        for (index, (raw, code)) in content.lines().zip(masked.lines()).enumerate() {
            let line_number = index + 1;
            if ansi.is_match(raw) && context.allows_line(&path, line_number) {
                current.push(Finding {
                    rule: "TASTE-ANSI",
                    path: path.clone(),
                    line: line_number,
                    message: "hardcoded ANSI escape sequence".to_string(),
                });
            }
            if panic.is_match(raw) && context.allows_line(&path, line_number) {
                current.push(Finding {
                    rule: "TASTE-PANIC-MSG",
                    path: path.clone(),
                    line: line_number,
                    message: "panic! lacks a meaningful message".to_string(),
                });
            }
            if function.is_match(code) {
                pending_async = true;
            }
            if pending_async && code.contains(';') && !code.contains('{') {
                pending_async = false;
            }
            let delta = brace_delta(code);
            if pending_async && code.contains('{') {
                async_depth = Some(depth + delta);
                pending_async = false;
            }
            if async_depth.is_some()
                && unwrap_call.is_match(code)
                && context.allows_line(&path, line_number)
            {
                current.push(Finding {
                    rule: "TASTE-ASYNC-UNWRAP",
                    path: path.clone(),
                    line: line_number,
                    message: "unwrap()/expect() inside async fn".to_string(),
                });
            }
            depth += delta;
            if async_depth.is_some_and(|end| depth < end || depth == 0) {
                async_depth = None;
            }
        }
        findings.extend(context.keep_unsuppressed(&content, current));
    }
    Ok(ScanResult::new(
        findings,
        "Taste invariants check passed — no issues found.",
        "Found {count} taste invariant violation(s):",
        &[],
    ))
}

#[derive(Default)]
struct RustLexer {
    block_comment_depth: usize,
    in_string: bool,
    raw_end: Option<String>,
}

pub(super) fn mask_rust_non_code(source: &str) -> String {
    lex_rust(source, false)
}

pub(super) fn strip_rust_comments(source: &str) -> String {
    lex_rust(source, true)
}

fn lex_rust(source: &str, preserve_literals: bool) -> String {
    let bytes = source.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut lexer = RustLexer::default();
    let mut index = 0;
    while index < bytes.len() {
        if let Some(end) = lexer.raw_end.as_deref() {
            if bytes[index..].starts_with(end.as_bytes()) {
                if preserve_literals {
                    output.extend_from_slice(&bytes[index..index + end.len()]);
                } else {
                    output.extend(std::iter::repeat_n(b' ', end.len()));
                }
                index += end.len();
                lexer.raw_end = None;
            } else {
                output.push(if preserve_literals || bytes[index] == b'\n' {
                    bytes[index]
                } else {
                    b' '
                });
                index += 1;
            }
            continue;
        }
        if lexer.in_string {
            if bytes[index] == b'\\' && index + 1 < bytes.len() {
                if preserve_literals {
                    output.extend_from_slice(&bytes[index..index + 2]);
                } else if bytes[index + 1] == b'\n' {
                    output.extend_from_slice(b" \n");
                } else {
                    output.extend_from_slice(b"  ");
                }
                index += 2;
            } else if bytes[index] == b'"' {
                output.push(if preserve_literals { b'"' } else { b' ' });
                index += 1;
                lexer.in_string = false;
            } else {
                output.push(if preserve_literals || bytes[index] == b'\n' {
                    bytes[index]
                } else {
                    b' '
                });
                index += 1;
            }
            continue;
        }
        if lexer.block_comment_depth > 0 {
            if bytes[index..].starts_with(b"/*") {
                output.extend_from_slice(b"  ");
                index += 2;
                lexer.block_comment_depth += 1;
            } else if bytes[index..].starts_with(b"*/") {
                output.extend_from_slice(b"  ");
                index += 2;
                lexer.block_comment_depth -= 1;
            } else {
                output.push(if bytes[index] == b'\n' { b'\n' } else { b' ' });
                index += 1;
            }
            continue;
        }
        if bytes[index..].starts_with(b"//") {
            while index < bytes.len() && bytes[index] != b'\n' {
                output.push(b' ');
                index += 1;
            }
            continue;
        }
        if bytes[index..].starts_with(b"/*") {
            output.extend_from_slice(b"  ");
            index += 2;
            lexer.block_comment_depth = 1;
            continue;
        }
        if let Some((length, end)) = raw_string_start(&bytes[index..]) {
            if preserve_literals {
                output.extend_from_slice(&bytes[index..index + length]);
            } else {
                output.extend(std::iter::repeat_n(b' ', length));
            }
            index += length;
            lexer.raw_end = Some(end);
            continue;
        }
        if bytes[index] == b'"' {
            output.push(if preserve_literals { b'"' } else { b' ' });
            index += 1;
            lexer.in_string = true;
            continue;
        }
        if bytes[index] == b'\''
            && let Some(length) = char_literal_length(&bytes[index..])
        {
            if preserve_literals {
                output.extend_from_slice(&bytes[index..index + length]);
            } else {
                output.extend(std::iter::repeat_n(b' ', length));
            }
            index += length;
            continue;
        }
        output.push(bytes[index]);
        index += 1;
    }
    String::from_utf8(output).expect("masked Rust preserves UTF-8 byte positions")
}

fn raw_string_start(bytes: &[u8]) -> Option<(usize, String)> {
    let prefix = if bytes.starts_with(b"br") || bytes.starts_with(b"cr") {
        2
    } else if bytes.starts_with(b"r") {
        1
    } else {
        return None;
    };
    let mut marker = prefix;
    while bytes.get(marker) == Some(&b'#') {
        marker += 1;
    }
    if bytes.get(marker) != Some(&b'"') {
        return None;
    }
    let hashes = marker - prefix;
    Some((marker + 1, format!("\"{}", "#".repeat(hashes))))
}

fn char_literal_length(bytes: &[u8]) -> Option<usize> {
    if bytes.first() != Some(&b'\'') {
        return None;
    }
    let mut index = 1;
    if bytes.get(index) == Some(&b'\\') {
        index += 2;
        if bytes.get(index.saturating_sub(1)) == Some(&b'u') && bytes.get(index) == Some(&b'{') {
            index += 1;
            while bytes.get(index).is_some_and(|byte| *byte != b'}') {
                index += 1;
            }
            index += 1;
        } else if bytes.get(index.saturating_sub(1)) == Some(&b'x') {
            index += 2;
        }
    } else {
        index += 1;
    }
    (bytes.get(index) == Some(&b'\'')).then_some(index + 1)
}

fn test_scope_lines(masked: &str) -> std::collections::BTreeSet<usize> {
    let item_keywords = [
        "mod ", "fn ", "impl ", "struct ", "enum ", "type ", "trait ",
    ];
    let mut result = std::collections::BTreeSet::new();
    let mut pending_attribute = false;
    let mut pending_item = false;
    let mut test_depth = None;
    let mut depth = 0isize;
    for (index, line) in masked.lines().enumerate() {
        let line_number = index + 1;
        let trimmed = line.trim();
        if trimmed.starts_with("#[cfg(test)]") {
            result.insert(line_number);
            let tail = trimmed.trim_start_matches("#[cfg(test)]").trim_start();
            if item_keywords.iter().any(|keyword| tail.contains(keyword)) {
                if tail.contains('{') {
                    test_depth = Some(depth + brace_delta(line));
                } else if !tail.contains(';') {
                    pending_item = true;
                }
            } else {
                pending_attribute = true;
            }
        } else if pending_attribute && trimmed.starts_with("#[") {
            result.insert(line_number);
        } else if pending_attribute {
            pending_attribute = false;
            if item_keywords
                .iter()
                .any(|keyword| trimmed.contains(keyword))
            {
                result.insert(line_number);
                if trimmed.contains('{') {
                    test_depth = Some(depth + brace_delta(line));
                } else if !trimmed.contains(';') {
                    pending_item = true;
                }
            }
        } else if pending_item {
            result.insert(line_number);
            if trimmed.contains('{') {
                test_depth = Some(depth + brace_delta(line));
                pending_item = false;
            } else if trimmed.contains(';') {
                pending_item = false;
            }
        } else if test_depth.is_some() {
            result.insert(line_number);
        }
        depth += brace_delta(line);
        if test_depth.is_some_and(|end| depth < end || depth == 0) {
            test_depth = None;
        }
    }
    result
}

struct UnwrapCallSite {
    line: usize,
    key: String,
}

fn unwrap_call_sites(masked: &str, pattern: &Regex) -> Vec<UnwrapCallSite> {
    let functions = function_names_by_line(masked);
    let lines = masked.lines().collect::<Vec<_>>();
    pattern
        .find_iter(masked)
        .map(|found| {
            let method_offset = found
                .as_str()
                .find("unwrap")
                .or_else(|| found.as_str().find("expect"))
                .unwrap_or(0);
            let line = masked.as_bytes()[..found.start() + method_offset]
                .iter()
                .filter(|byte| **byte == b'\n')
                .count()
                + 1;
            let function = functions
                .get(line - 1)
                .and_then(|value| value.as_deref())
                .unwrap_or("<module>");
            let source_line = lines.get(line - 1).copied().unwrap_or("");
            let normalized = source_line.split_whitespace().collect::<String>();
            UnwrapCallSite {
                line,
                key: format!("{function}:{normalized}"),
            }
        })
        .collect()
}

fn function_names_by_line(masked: &str) -> Vec<Option<String>> {
    let mut names = Vec::new();
    let mut active: Option<(String, isize, bool)> = None;
    let mut depth = 0isize;
    for line in masked.lines() {
        if active.is_none()
            && let Some(name) = rust_function_name(line)
        {
            active = Some((name.to_string(), depth, line.contains('{')));
        }
        names.push(active.as_ref().map(|(name, _, _)| name.clone()));
        if let Some((_, _, entered)) = active.as_mut() {
            *entered |= line.contains('{');
            if !*entered && line.contains(';') {
                active = None;
            }
        }
        depth += brace_delta(line);
        if active
            .as_ref()
            .is_some_and(|(_, base, entered)| *entered && depth <= *base)
        {
            active = None;
        }
    }
    names
}

fn rust_function_name(line: &str) -> Option<&str> {
    let bytes = line.as_bytes();
    let mut search = 0;
    while let Some(offset) = line[search..].find("fn") {
        let start = search + offset;
        let boundary_before = start == 0 || !is_rust_ident(bytes[start - 1]);
        let mut index = start + 2;
        let boundary_after = bytes
            .get(index)
            .is_some_and(|byte| byte.is_ascii_whitespace());
        if boundary_before && boundary_after {
            while bytes
                .get(index)
                .is_some_and(|byte| byte.is_ascii_whitespace())
            {
                index += 1;
            }
            let name_start = index;
            while bytes.get(index).is_some_and(|byte| is_rust_ident(*byte)) {
                index += 1;
            }
            if index > name_start {
                return Some(&line[name_start..index]);
            }
        }
        search = start + 2;
    }
    None
}

fn is_rust_ident(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_'
}

fn lock_binding_name(statement_prefix: &str, line: &str, lock_position: usize) -> Option<String> {
    let prefix = format!("{statement_prefix}{}", &line[..lock_position]);
    let statement_start = prefix
        .rfind([';', '{', '}'])
        .map_or(0, |position| position + 1);
    let statement = &prefix[statement_start..];
    let assignment = assignment_position(statement)?;
    let name = statement[..assignment]
        .split(':')
        .next()?
        .split_whitespace()
        .next_back()?;
    if name.bytes().all(is_rust_ident) {
        Some(name.to_string())
    } else if statement.trim_start().starts_with("let ") {
        Some("$pattern".to_string())
    } else {
        None
    }
}

fn assignment_position(text: &str) -> Option<usize> {
    let bytes = text.as_bytes();
    bytes.iter().enumerate().position(|(index, byte)| {
        *byte == b'='
            && !bytes
                .get(index.saturating_sub(1))
                .is_some_and(|previous| matches!(previous, b'=' | b'!' | b'<' | b'>'))
            && !bytes
                .get(index + 1)
                .is_some_and(|next| matches!(next, b'=' | b'>'))
    })
}

fn brace_delta(line: &str) -> isize {
    line.matches('{').count() as isize - line.matches('}').count() as isize
}
