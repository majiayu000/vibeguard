use regex::Regex;

use super::shared::{Finding, Result, ScanContext, ScanResult};

pub(super) fn error_handling(context: &ScanContext) -> Result<ScanResult> {
    let call = Regex::new(
        r"(?m)(?:^|[;{}:])[ \t]*(?:_(?:[ \t]*,[ \t\r\n]*_)?|[A-Za-z_][A-Za-z0-9_]*(?:[ \t\r\n]*\.[ \t\r\n]*[A-Za-z_][A-Za-z0-9_]*)*[ \t]*,[ \t\r\n]*_)[ \t]*:?=[ \t\r\n]*(?:[A-Za-z_][A-Za-z0-9_]*(?:[ \t\r\n]*\.[ \t\r\n]*(?:[A-Za-z_][A-Za-z0-9_]*|\([^()\n]+\)))*(?:\[[^\n()]+\])?|\([^\n()]+\)(?:[ \t\r\n]*\.[ \t\r\n]*[A-Za-z_][A-Za-z0-9_]*)?)[ \t\r\n]*\(",
    )?;
    let mut findings = Vec::new();
    for path in production_files(context) {
        let content = context.read(&path)?;
        let masked = mask_go_non_code(&content);
        let current = call
            .find_iter(&masked)
            .filter_map(|found| {
                let matched = found.as_str();
                let assignment = found.start() + matched.find('_').unwrap_or(0);
                let line = masked.as_bytes()[..assignment]
                    .iter()
                    .filter(|byte| **byte == b'\n')
                    .count()
                    + 1;
                let end_line = line + matched.matches('\n').count();
                (line..=end_line)
                    .any(|candidate| context.allows_line(&path, candidate))
                    .then(|| Finding {
                        rule: "GO-01",
                        path: path.clone(),
                        line,
                        message:
                            "[auto-fix] [this-line] OBSERVATION: error return value is discarded"
                                .to_string(),
                    })
            })
            .collect();
        findings.extend(context.keep_unsuppressed(&content, current));
    }
    Ok(ScanResult::new(
        findings,
        "No unchecked error returns found.",
        "Found {count} unchecked error return(s).",
        &[
            "SCOPE: this-line only — do not modify function signatures or upstream callers",
            "ACTION: REVIEW",
        ],
    ))
}

fn mask_go_non_code(source: &str) -> String {
    let bytes = source.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    let mut in_block_comment = false;
    let mut quoted = None;
    while index < bytes.len() {
        if let Some(end) = quoted {
            if end != b'`' && bytes[index] == b'\\' && index + 1 < bytes.len() {
                output.extend_from_slice(b"  ");
                index += 2;
            } else if bytes[index] == end {
                output.push(b' ');
                index += 1;
                quoted = None;
            } else {
                output.push(if bytes[index] == b'\n' { b'\n' } else { b' ' });
                index += 1;
            }
            continue;
        }
        if in_block_comment {
            if bytes[index..].starts_with(b"*/") {
                output.extend_from_slice(b"  ");
                index += 2;
                in_block_comment = false;
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
        } else if bytes[index..].starts_with(b"/*") {
            output.extend_from_slice(b"  ");
            index += 2;
            in_block_comment = true;
        } else if matches!(bytes[index], b'"' | b'\'' | b'`') {
            quoted = Some(bytes[index]);
            output.push(b' ');
            index += 1;
        } else {
            output.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(output).expect("masked Go preserves UTF-8 byte positions")
}

pub(super) fn goroutine_leak(context: &ScanContext) -> Result<ScanResult> {
    let launch = Regex::new(r"^\s*go\s+(?:func\s*\(|[A-Za-z_])")?;
    let infinite = Regex::new(r"^\s*for\s*\{")?;
    let exit = Regex::new(
        r"ctx\.Done|context\.WithCancel|wg\.(?:Add|Done|Wait)|errgroup|<-done|<-quit|<-stop|time\.After|ticker|\b(?:return|break)\b",
    )?;
    let mut findings = Vec::new();
    for path in production_files(context) {
        let content = context.read(&path)?;
        let lines = content.lines().collect::<Vec<_>>();
        let masked = mask_go_non_code(&content);
        let code_lines = masked.lines().collect::<Vec<_>>();
        let mut current = Vec::new();
        for (index, line) in code_lines.iter().enumerate() {
            let line_number = index + 1;
            let body_end = if launch.is_match(line) {
                brace_block_end(&code_lines, index)
            } else {
                index
            };
            let changed = context.allows_line(&path, line_number)
                || context.has_deleted_between(&path, line_number, body_end + 1, &exit);
            if !changed {
                continue;
            }
            let body = code_lines[index..=body_end].join("\n");
            if launch.is_match(line) && !exit.is_match(&body) {
                current.push(Finding {
                    rule: "GO-02",
                    path: path.clone(),
                    line: line_number,
                    message: lines[index].trim().to_string(),
                });
            }
            if infinite.is_match(line) {
                current.push(Finding {
                    rule: "GO-02/loop",
                    path: path.clone(),
                    line: line_number,
                    message: line.trim().to_string(),
                });
            }
        }
        findings.extend(context.keep_unsuppressed(&content, current));
    }
    Ok(ScanResult::new(
        findings,
        "No goroutine leak risks found.",
        "Found {count} goroutine launch/infinite loop site(s) to review.",
        &[
            "Repair method:",
            "1. Pass in context.Context and exit through <-ctx.Done()",
            "2. Use errgroup.Group to manage goroutine life cycle",
            "3. The for {} loop must have select + exit branch",
            "4. Make sure each go func() has a clear exit path",
        ],
    ))
}

fn brace_block_end(lines: &[&str], start: usize) -> usize {
    let mut depth = 0isize;
    let mut entered = false;
    for (index, line) in lines.iter().enumerate().skip(start) {
        for character in line.chars() {
            match character {
                '{' => {
                    entered = true;
                    depth += 1;
                }
                '}' if entered => {
                    depth -= 1;
                    if depth == 0 {
                        return index;
                    }
                }
                _ => {}
            }
        }
    }
    lines.len().saturating_sub(1).min(start.saturating_add(20))
}

pub(super) fn defer_in_loop(context: &ScanContext) -> Result<ScanResult> {
    let loop_start = Regex::new(r"^\s*for(?:\s|$)")?;
    let defer = Regex::new(r"^\s*defer\s")?;
    let function_literal = Regex::new(r"(?:^|[^A-Za-z0-9_])func\s*\(")?;
    let mut findings = Vec::new();
    for path in production_files(context) {
        let content = context.read(&path)?;
        let mut total_depth = 0isize;
        let mut loops: Vec<(isize, usize)> = Vec::new();
        let mut function_literals: Vec<isize> = Vec::new();
        let mut current = Vec::new();
        for (index, raw_line) in content.lines().enumerate() {
            let line_number = index + 1;
            let line = raw_line.split("//").next().unwrap_or("");
            if loop_start.is_match(line) {
                loops.push((total_depth, line_number));
            }
            if !loops.is_empty() && !defer.is_match(line) && function_literal.is_match(line) {
                function_literals.push(total_depth);
            }
            if defer.is_match(line) && !loops.is_empty() && function_literals.is_empty() {
                let loop_line = loops.last().map(|(_, line)| *line).unwrap_or(line_number);
                if context.allows_line(&path, line_number) || context.allows_line(&path, loop_line)
                {
                    current.push(Finding {
                        rule: "GO-08",
                        path: path.clone(),
                        line: line_number,
                        message: raw_line.trim().to_string(),
                    });
                }
            }
            total_depth += line.matches('{').count() as isize - line.matches('}').count() as isize;
            while function_literals
                .last()
                .is_some_and(|base| total_depth <= *base)
            {
                function_literals.pop();
            }
            while loops.last().is_some_and(|(base, _)| total_depth <= *base) {
                loops.pop();
            }
        }
        findings.extend(context.keep_unsuppressed(&content, current));
    }
    Ok(ScanResult::new(
        findings,
        "No defer-in-loop issues found.",
        "Found {count} defer-in-loop issue(s).",
        &["Repair method: extract the loop body containing defer into a separate function."],
    ))
}

fn production_files(context: &ScanContext) -> Vec<std::path::PathBuf> {
    context
        .files_with_extensions(&["go"])
        .into_iter()
        .filter(|path| {
            !path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.ends_with("_test.go"))
                && !path
                    .to_string_lossy()
                    .replace('\\', "/")
                    .contains("/vendor/")
        })
        .collect()
}
