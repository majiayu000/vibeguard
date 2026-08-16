use regex::Regex;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use crate::hook_checks::js::mask_javascript_non_code;

use super::shared::{Finding, Result, ScanContext, ScanResult, is_typescript_test_path};

fn mask_typescript_non_code(source: &str, path: &Path) -> String {
    if matches!(
        path.extension().and_then(|value| value.to_str()),
        Some("tsx" | "jsx")
    ) {
        mask_javascript_non_code(&source.replace("</", "< "))
    } else {
        mask_javascript_non_code(source)
    }
}

pub(super) fn any_abuse(context: &ScanContext) -> Result<ScanResult> {
    let mut findings = Vec::new();
    for path in production_files(context) {
        let content = context.read(&path)?;
        let masked = mask_typescript_non_code(&content, &path);
        let raw_lines = content.lines().collect::<Vec<_>>();
        let mut current = Vec::new();
        for line_number in any_type_lines(&masked) {
            if context.allows_line(&path, line_number) {
                current.push(Finding {
                    rule: "TS-01",
                    path: path.clone(),
                    line: line_number,
                    message: "[review] [this-line] OBSERVATION: 'any' type usage".to_string(),
                });
            }
        }
        for (index, _) in masked.lines().enumerate() {
            let line_number = index + 1;
            let raw = raw_lines.get(index).copied().unwrap_or("");
            if context.allows_line(&path, line_number) && raw.contains("@ts-ignore") {
                current.push(Finding {
                    rule: "TS-02",
                    path: path.clone(),
                    line: line_number,
                    message:
                        "[review] [this-line] OBSERVATION: uses '@ts-ignore' to suppress type check"
                            .to_string(),
                });
            }
            if context.allows_line(&path, line_number) && raw.contains("@ts-nocheck") {
                current.push(Finding {
                    rule: "TS-02",
                    path: path.clone(),
                    line: line_number,
                    message: "[review] [this-line] OBSERVATION: uses '@ts-nocheck' to disable type checking for entire file".to_string(),
                });
            }
        }
        findings.extend(context.keep_unsuppressed(&content, current));
    }
    Ok(ScanResult::new(
        findings,
        "[TS-01] PASS: no type abuse detected",
        "[TS-01/TS-02] {count} type suppression instance(s):",
        &[
            "SCOPE: this-line only — do not modify tsconfig.json, disable type checking globally, or broaden suppressions",
            "ACTION: REVIEW",
        ],
    ))
}

pub(super) fn console_residual(context: &ScanContext) -> Result<ScanResult> {
    if is_cli_project(&context.target) {
        return Ok(ScanResult::new(
            Vec::new(),
            "[TS-03] SKIP: CLI project, console is the normal output mode",
            "",
            &[],
        ));
    }
    let cli_exemption_removed = previous_cli_project(context)?;
    let console = Regex::new(
        r"\bconsole[ \t\r\n]*(?:\.|\?\.)[ \t\r\n]*[A-Za-z_$][A-Za-z0-9_$]*[ \t\r\n]*(?:\?\.)?[ \t\r\n]*\(",
    )?;
    let mut findings = Vec::new();
    for path in production_files(context) {
        let relative = path.strip_prefix(&context.target).unwrap_or(&path);
        let normalized = relative
            .to_string_lossy()
            .replace('\\', "/")
            .to_ascii_lowercase();
        if normalized.contains("logger")
            || normalized.contains("logging")
            || normalized.contains("log.config")
            || normalized.contains("/debug.")
            || normalized.contains("/debug/")
        {
            continue;
        }
        let content = context.read(&path)?;
        if ["StdioServerTransport", "new Server(", "McpServer"]
            .iter()
            .any(|marker| content.contains(marker))
        {
            continue;
        }
        let mcp_exemption_removed = context.previous_content(&path)?.is_some_and(|previous| {
            ["StdioServerTransport", "new Server(", "McpServer"]
                .iter()
                .any(|marker| previous.contains(marker))
        });
        let masked = mask_typescript_non_code(&content, &path);
        let current = console
            .find_iter(&masked)
            .filter_map(|found| {
                let line = masked.as_bytes()[..found.start()]
                    .iter()
                    .filter(|byte| **byte == b'\n')
                    .count()
                    + 1;
                let end_line = line + found.as_str().matches('\n').count();
                (cli_exemption_removed
                    || mcp_exemption_removed
                    || (line..=end_line).any(|candidate| context.allows_line(&path, candidate)))
                .then(|| Finding {
                    rule: "TS-03",
                    path: path.clone(),
                    line,
                    message: "[review] [this-line] OBSERVATION: console residual".to_string(),
                })
            })
            .collect();
        findings.extend(context.keep_unsuppressed(&content, current));
    }
    Ok(ScanResult::new(
        findings,
        "[TS-03] PASS: No console residue detected",
        "[TS-03] {count} console residual instance(s):",
        &[
            "SCOPE: this-line only — do not create logger modules, modify other files, or fix console usage outside this line",
            "ACTION: REVIEW — skip if this is a CLI project (check bin field in package.json)",
        ],
    ))
}

pub(super) fn duplicate_constants(context: &ScanContext) -> Result<ScanResult> {
    if !context.target.join("src").is_dir() {
        return Ok(ScanResult::new(
            Vec::new(),
            "[PASS] No src/ directory found",
            "",
            &[],
        ));
    }
    let constant = Regex::new(r"\bexport\s+const\s+([A-Z][A-Z_]*)\b")?;
    let type_definition = Regex::new(r"\bexport\s+(?:type|interface)\s+([A-Z][A-Za-z]*)\b")?;
    let function = Regex::new(r"\bfunction\s+([a-z][A-Za-z]*)\b")?;
    let mut constants = BTreeMap::new();
    let mut types = BTreeMap::new();
    let mut functions = BTreeMap::new();
    for path in all_production_files(context) {
        if !path.starts_with(context.target.join("src")) {
            continue;
        }
        let content = context.read(&path)?;
        let masked = mask_typescript_non_code(&content, &path);
        collect_names(&constant, &masked, &path, &mut constants);
        collect_names(&type_definition, &masked, &path, &mut types);
        collect_names(&function, &masked, &path, &mut functions);
    }
    let mut findings = duplicate_name_findings(context, "DUP-CONST", constants, 2);
    findings.extend(duplicate_name_findings(context, "DUP-TYPE", types, 2));
    findings.extend(duplicate_name_findings(context, "DUP-FUNC", functions, 3));
    Ok(ScanResult::new(
        findings,
        "=== Summary: 0 duplicate issues found ===",
        "=== Summary: {count} duplicate issues found ===",
        &["Remediation: keep one definition and import it from the shared module."],
    ))
}

pub(super) fn component_duplication(context: &ScanContext) -> Result<ScanResult> {
    if !context.target.join("src").is_dir() {
        return Ok(ScanResult::new(
            Vec::new(),
            "[PASS] No src/ directory found",
            "",
            &[],
        ));
    }
    let mut form_fields = Vec::new();
    let mut sortable_tables = Vec::new();
    let mut query_hooks = Vec::new();
    let style = Regex::new(r#"(?:className|class|Style)\s*[:=]\s*['\"]([^'\"]{60,})['\"]"#)?;
    let required = Regex::new(r"required\s*[?:}]")?;
    let sort_state = Regex::new(r"useState.*sort|setSortKey|setSortDir|setSortOrder")?;
    let table = Regex::new(r"<table|<Table|<th|<thead")?;
    let query = Regex::new(r"useQuery|useSWR|useInfiniteQuery")?;
    let query_state = Regex::new(r"isLoading|loading.*error|refetch|data.*error")?;
    let mut styles: BTreeMap<String, BTreeSet<(std::path::PathBuf, usize)>> = BTreeMap::new();
    for path in production_files(context) {
        let content = context.read(&path)?;
        let previous = context.previous_content(&path)?;
        if form_field_like(&content, &required) {
            form_fields.push((
                path.clone(),
                previous
                    .as_deref()
                    .is_none_or(|value| !form_field_like(value, &required)),
            ));
        }
        if sortable_table_like(&content, &sort_state, &table) {
            sortable_tables.push((
                path.clone(),
                previous
                    .as_deref()
                    .is_none_or(|value| !sortable_table_like(value, &sort_state, &table)),
            ));
        }
        if query_hook_like(&path, &content, &query, &query_state) {
            query_hooks.push((
                path.clone(),
                previous.as_deref().is_none_or(|value| {
                    !query_hook_like(context.previous_path(&path), value, &query, &query_state)
                }),
            ));
        }
        for captures in style.captures_iter(&content) {
            let line = content.as_bytes()[..captures.get(0).map_or(0, |value| value.start())]
                .iter()
                .filter(|byte| **byte == b'\n')
                .count()
                + 1;
            styles
                .entry(captures[1].to_string())
                .or_default()
                .insert((path.clone(), line));
        }
    }
    let mut findings = Vec::new();
    if form_fields.len() >= 3 {
        findings.extend(group_finding(
            "TS-13",
            "FormField-like pattern",
            &form_fields,
        ));
    }
    if sortable_tables.len() >= 2 {
        findings.extend(group_finding(
            "TS-13",
            "Sortable table pattern",
            &sortable_tables,
        ));
    }
    if query_hooks.len() >= 4 {
        findings.extend(group_finding(
            "TS-13",
            "Query hook template pattern",
            &query_hooks,
        ));
    }
    for (value, paths) in styles {
        if paths
            .iter()
            .map(|(path, _)| path)
            .collect::<BTreeSet<_>>()
            .len()
            >= 2
            && let Some((changed_path, changed_line)) = paths
                .iter()
                .find(|(path, line)| context.allows_line(path, *line))
        {
            findings.push(Finding {
                rule: "TS-13",
                path: changed_path.clone(),
                line: *changed_line,
                message: format!(
                    "Style string duplicated {} times: {}...",
                    paths.len(),
                    value.chars().take(80).collect::<String>()
                ),
            });
        }
    }
    Ok(ScanResult::new(
        findings,
        "=== Summary: 0 component/hook duplication issues found ===",
        "=== Summary: {count} component/hook duplication issues found ===",
        &["Remediation: extract the repeated component, hook, or style constant."],
    ))
}

fn collect_names(
    pattern: &Regex,
    content: &str,
    path: &Path,
    output: &mut BTreeMap<String, BTreeSet<(std::path::PathBuf, usize)>>,
) {
    for (index, line) in content.lines().enumerate() {
        for captures in pattern.captures_iter(line) {
            output
                .entry(captures[1].to_string())
                .or_default()
                .insert((path.to_path_buf(), index + 1));
        }
    }
}

fn duplicate_name_findings(
    context: &ScanContext,
    rule: &'static str,
    definitions: BTreeMap<String, BTreeSet<(std::path::PathBuf, usize)>>,
    threshold: usize,
) -> Vec<Finding> {
    definitions
        .into_iter()
        .filter(|(_, locations)| {
            locations
                .iter()
                .map(|(path, _)| path)
                .collect::<BTreeSet<_>>()
                .len()
                >= threshold
        })
        .filter_map(|(name, locations)| {
            let changed = locations
                .iter()
                .find(|(path, line)| context.allows_line(path, *line))?;
            let paths = locations
                .iter()
                .map(|(path, _)| path)
                .collect::<BTreeSet<_>>();
            Some(Finding {
                rule,
                path: changed.0.clone(),
                line: changed.1,
                message: format!(
                    "{name} defined in {} files: {}",
                    paths.len(),
                    paths
                        .iter()
                        .map(|path| path.display().to_string())
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            })
        })
        .collect()
}

fn group_finding(
    rule: &'static str,
    label: &str,
    paths: &[(std::path::PathBuf, bool)],
) -> Option<Finding> {
    let changed = paths.iter().find(|(_, changed)| *changed)?;
    Some(Finding {
        rule,
        path: changed.0.clone(),
        line: 1,
        message: format!(
            "{label} found in {} files: {}",
            paths.len(),
            paths
                .iter()
                .map(|(path, _)| path.display().to_string())
                .collect::<Vec<_>>()
                .join(", ")
        ),
    })
}

fn form_field_like(content: &str, required: &Regex) -> bool {
    content.contains("<label")
        && (content.contains("{children}") || content.contains("{props.children}"))
        && (content.contains("isRequired")
            || required.is_match(content)
            || content.contains("props.required"))
}

fn sortable_table_like(content: &str, sort_state: &Regex, table: &Regex) -> bool {
    sort_state.is_match(content) && table.is_match(content)
}

fn query_hook_like(path: &Path, content: &str, query: &Regex, state: &Regex) -> bool {
    let normalized = path
        .to_string_lossy()
        .replace('\\', "/")
        .to_ascii_lowercase();
    (normalized.contains("/hooks/")
        || path
            .file_name()
            .and_then(|value| value.to_str())
            .is_some_and(|name| name.starts_with("use")))
        && query.is_match(content)
        && state.is_match(content)
}

fn production_files(context: &ScanContext) -> Vec<std::path::PathBuf> {
    context
        .files_with_extensions(&["ts", "tsx", "js", "jsx"])
        .into_iter()
        .filter(|path| !is_typescript_test_path(path))
        .collect()
}

fn all_production_files(context: &ScanContext) -> Vec<std::path::PathBuf> {
    context
        .all_files_with_extensions(&["ts", "tsx", "js", "jsx"])
        .into_iter()
        .filter(|path| !is_typescript_test_path(path))
        .collect()
}

fn is_cli_project(target: &Path) -> bool {
    let package = target.join("package.json");
    if let Ok(content) = std::fs::read_to_string(package)
        && is_cli_manifest(&content)
    {
        return true;
    }
    ["ts", "tsx", "js", "jsx"].iter().any(|extension| {
        target.join(format!("src/cli.{extension}")).exists()
            || target.join(format!("cli.{extension}")).exists()
    })
}

fn previous_cli_project(context: &ScanContext) -> Result<bool> {
    if context
        .previous_content(&context.target.join("package.json"))?
        .is_some_and(|content| is_cli_manifest(&content))
    {
        return Ok(true);
    }
    for extension in ["ts", "tsx", "js", "jsx"] {
        for relative in [format!("src/cli.{extension}"), format!("cli.{extension}")] {
            if context
                .previous_content(&context.target.join(relative))?
                .is_some()
            {
                return Ok(true);
            }
        }
    }
    Ok(false)
}

fn is_cli_manifest(content: &str) -> bool {
    content.contains("\"bin\"")
        || Regex::new(r#""[^"]+"\s*:\s*"[^"]*cli[^"]*""#)
            .expect("valid CLI regex")
            .is_match(content)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum BraceKind {
    Object,
    Type,
    Block,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Delimiter {
    Brace(BraceKind),
    Paren,
    Bracket,
}

#[derive(Clone)]
struct TypeToken {
    text: String,
    line: usize,
}

fn any_type_lines(masked: &str) -> BTreeSet<usize> {
    let tokens = type_tokens(masked);
    let mut findings = BTreeSet::new();
    let mut stack = Vec::new();
    let mut object_colons = BTreeSet::new();
    for (index, token) in tokens.iter().enumerate() {
        match token.text.as_str() {
            "{" => {
                let kind = classify_brace(&tokens, index, &object_colons);
                stack.push(Delimiter::Brace(kind));
            }
            "(" => stack.push(Delimiter::Paren),
            "[" => stack.push(Delimiter::Bracket),
            "}" => pop_delimiter(&mut stack, |value| matches!(value, Delimiter::Brace(_))),
            ")" => pop_delimiter(&mut stack, |value| value == Delimiter::Paren),
            "]" => pop_delimiter(&mut stack, |value| value == Delimiter::Bracket),
            ":" if is_object_property_colon(&tokens, index, &stack) => {
                object_colons.insert(index);
            }
            "any" if any_is_type(&tokens, index, &object_colons, &stack) => {
                findings.insert(token.line);
            }
            _ => {}
        }
    }
    findings
}

fn any_is_type(
    tokens: &[TypeToken],
    index: usize,
    object_colons: &BTreeSet<usize>,
    stack: &[Delimiter],
) -> bool {
    for cursor in (0..index).rev() {
        match tokens[cursor].text.as_str() {
            ":" => {
                return !object_colons.contains(&cursor)
                    && !is_value_ternary_colon(tokens, cursor)
                    && !is_case_or_label_colon(tokens, cursor, stack);
            }
            "as" => return as_starts_type(tokens, cursor),
            "," if !inside_type_container(tokens, cursor) => return false,
            "=" => return statement_is_type_alias(tokens, cursor),
            ";" | "{" | "}" => return false,
            _ => {}
        }
    }
    false
}

fn is_case_or_label_colon(tokens: &[TypeToken], colon: usize, stack: &[Delimiter]) -> bool {
    let start = tokens[..colon]
        .iter()
        .rposition(|token| matches!(token.text.as_str(), ";" | "{" | "}"))
        .map_or(0, |position| position + 1);
    let statement = &tokens[start..colon];
    if statement
        .first()
        .is_some_and(|token| matches!(token.text.as_str(), "case" | "default"))
    {
        return true;
    }
    matches!(stack.last(), Some(Delimiter::Brace(BraceKind::Block)))
        && statement.len() == 1
        && statement[0]
            .text
            .as_bytes()
            .first()
            .is_some_and(|byte| byte.is_ascii_alphabetic() || matches!(byte, b'_' | b'$'))
}

fn as_starts_type(tokens: &[TypeToken], index: usize) -> bool {
    let mut depth = 0usize;
    for cursor in (0..index).rev() {
        match tokens[cursor].text.as_str() {
            "}" => depth += 1,
            "{" if depth == 0 => {
                let start = tokens[..cursor]
                    .iter()
                    .rposition(|token| matches!(token.text.as_str(), ";" | "}"))
                    .map_or(0, |position| position + 1);
                return !tokens[start..cursor]
                    .iter()
                    .any(|token| matches!(token.text.as_str(), "import" | "export"));
            }
            "{" => depth -= 1,
            ";" if depth == 0 => break,
            _ => {}
        }
    }
    tokens
        .get(index.wrapping_sub(1))
        .is_none_or(|token| token.text != "*")
}

fn is_value_ternary_colon(tokens: &[TypeToken], colon: usize) -> bool {
    let start = tokens[..colon]
        .iter()
        .rposition(|token| matches!(token.text.as_str(), ";" | "{" | "}"))
        .map_or(0, |position| position + 1);
    let Some(question) = tokens[start..colon]
        .iter()
        .rposition(|token| token.text == "?")
        .map(|position| start + position)
    else {
        return false;
    };
    if question + 1 == colon {
        return false;
    }
    let prefix = &tokens[start..question];
    !prefix.iter().any(|token| token.text == "extends")
        && !prefix.iter().enumerate().any(|(offset, token)| {
            token.text == "=" && statement_is_type_alias(tokens, start + offset)
        })
}

fn inside_type_container(tokens: &[TypeToken], index: usize) -> bool {
    tokens[..index]
        .iter()
        .fold((0usize, 0usize), |(angle, bracket), token| {
            match token.text.as_str() {
                "<" => (angle + 1, bracket),
                ">" => (angle.saturating_sub(1), bracket),
                "[" => (angle, bracket + 1),
                "]" => (angle, bracket.saturating_sub(1)),
                _ => (angle, bracket),
            }
        })
        != (0, 0)
}

fn statement_is_type_alias(tokens: &[TypeToken], index: usize) -> bool {
    let start = tokens[..index]
        .iter()
        .rposition(|token| matches!(token.text.as_str(), ";" | "{" | "}"))
        .map_or(0, |position| position + 1);
    let statement = &tokens[start..index];
    statement.first().is_some_and(|token| token.text == "type")
        || statement.get(1).is_some_and(|token| token.text == "type")
            && statement
                .first()
                .is_some_and(|token| matches!(token.text.as_str(), "export" | "declare"))
}

fn type_tokens(masked: &str) -> Vec<TypeToken> {
    let bytes = masked.as_bytes();
    let mut tokens = Vec::new();
    let mut index = 0;
    let mut line = 1;
    while index < bytes.len() {
        if bytes[index] == b'\n' {
            line += 1;
            index += 1;
        } else if bytes[index].is_ascii_whitespace() {
            index += 1;
        } else if bytes[index].is_ascii_alphabetic() || matches!(bytes[index], b'_' | b'$') {
            let start = index;
            index += 1;
            while index < bytes.len()
                && (bytes[index].is_ascii_alphanumeric() || matches!(bytes[index], b'_' | b'$'))
            {
                index += 1;
            }
            tokens.push(TypeToken {
                text: masked[start..index].to_string(),
                line,
            });
        } else if bytes[index..].starts_with(b"=>") {
            tokens.push(TypeToken {
                text: "=>".to_string(),
                line,
            });
            index += 2;
        } else {
            tokens.push(TypeToken {
                text: (bytes[index] as char).to_string(),
                line,
            });
            index += 1;
        }
    }
    tokens
}

fn classify_brace(
    tokens: &[TypeToken],
    index: usize,
    object_colons: &BTreeSet<usize>,
) -> BraceKind {
    let previous = index.checked_sub(1).and_then(|value| tokens.get(value));
    if previous.is_some_and(|value| value.text == ":") {
        return if index
            .checked_sub(1)
            .is_some_and(|value| object_colons.contains(&value))
        {
            BraceKind::Object
        } else {
            BraceKind::Type
        };
    }
    let boundary = tokens[..index]
        .iter()
        .rposition(|token| matches!(token.text.as_str(), ";" | "{" | "}"));
    let statement = &tokens[boundary.map_or(0, |value| value + 1)..index];
    if statement
        .iter()
        .any(|token| matches!(token.text.as_str(), "class" | "interface"))
        || statement.first().is_some_and(|token| token.text == "type")
    {
        BraceKind::Type
    } else if (statement
        .iter()
        .take(2)
        .any(|token| matches!(token.text.as_str(), "const" | "let" | "var"))
        && !statement.iter().any(|token| token.text == "="))
        || previous
            .is_some_and(|token| matches!(token.text.as_str(), "=" | "(" | "[" | "," | "return"))
    {
        BraceKind::Object
    } else {
        BraceKind::Block
    }
}

fn is_object_property_colon(tokens: &[TypeToken], index: usize, stack: &[Delimiter]) -> bool {
    if !matches!(stack.last(), Some(Delimiter::Brace(BraceKind::Object))) {
        return false;
    }
    let Some(previous) = index.checked_sub(1).and_then(|value| tokens.get(value)) else {
        return false;
    };
    let (key_index, key) = if previous.text == "?" {
        let Some(key_index) = index.checked_sub(2) else {
            return false;
        };
        (key_index, &tokens[key_index])
    } else {
        (index - 1, previous)
    };
    if !key
        .text
        .as_bytes()
        .first()
        .is_some_and(|byte| byte.is_ascii_alphabetic() || matches!(byte, b'_' | b'$'))
    {
        return false;
    }
    key_index == 0 || matches!(tokens[key_index - 1].text.as_str(), "{" | "," | ";")
}

fn pop_delimiter(stack: &mut Vec<Delimiter>, matches: impl Fn(Delimiter) -> bool) {
    if let Some(position) = stack.iter().rposition(|value| matches(*value)) {
        stack.truncate(position);
    }
}
