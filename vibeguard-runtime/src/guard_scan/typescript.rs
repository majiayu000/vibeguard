use regex::Regex;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use crate::hook_checks::js::mask_javascript_non_code;

use super::shared::{Finding, Result, ScanContext, ScanResult, is_typescript_test_path};

pub(super) fn any_abuse(context: &ScanContext) -> Result<ScanResult> {
    let any_cast = Regex::new(r"\bas\s+any\b")?;
    let any_annotation = Regex::new(r":\s*any\b")?;
    let mut findings = Vec::new();
    for path in production_files(context) {
        let content = context.read(&path)?;
        let masked = mask_javascript_non_code(&content);
        let raw_lines = content.lines().collect::<Vec<_>>();
        let mut current = Vec::new();
        for (index, code) in masked.lines().enumerate() {
            let line_number = index + 1;
            if context.allows_line(&path, line_number)
                && (any_cast.is_match(code) || has_any_type_annotation(code, &any_annotation))
            {
                current.push(Finding {
                    rule: "TS-01",
                    path: path.clone(),
                    line: line_number,
                    message: "[review] [this-line] OBSERVATION: 'any' type usage".to_string(),
                });
            }
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
    let console = Regex::new(r"\bconsole\.(?:log|warn|error|info|debug|trace)\s*(?:\?\.)?\s*\(")?;
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
        let mcp_exemption_removed = context.previous_content(&path).is_some_and(|previous| {
            ["StdioServerTransport", "new Server(", "McpServer"]
                .iter()
                .any(|marker| previous.contains(marker))
        });
        let masked = mask_javascript_non_code(&content);
        let current = masked
            .lines()
            .enumerate()
            .filter(|(index, line)| {
                (mcp_exemption_removed || context.allows_line(&path, index + 1))
                    && console.is_match(line)
            })
            .map(|(index, _)| Finding {
                rule: "TS-03",
                path: path.clone(),
                line: index + 1,
                message: "[review] [this-line] OBSERVATION: console residual".to_string(),
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
    for path in production_files(context) {
        if !path.starts_with(context.target.join("src")) {
            continue;
        }
        let content = context.read(&path)?;
        let masked = mask_javascript_non_code(&content);
        collect_names(&constant, &masked, &path, &mut constants);
        collect_names(&type_definition, &masked, &path, &mut types);
        collect_names(&function, &masked, &path, &mut functions);
    }
    let mut findings = duplicate_name_findings("DUP-CONST", constants, 2);
    findings.extend(duplicate_name_findings("DUP-TYPE", types, 2));
    findings.extend(duplicate_name_findings("DUP-FUNC", functions, 3));
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
    let mut styles: BTreeMap<String, BTreeSet<std::path::PathBuf>> = BTreeMap::new();
    for path in production_files(context) {
        let content = context.read(&path)?;
        if content.contains("<label")
            && (content.contains("{children}") || content.contains("{props.children}"))
            && (content.contains("isRequired")
                || Regex::new(r"required\s*[?:}]")?.is_match(&content)
                || content.contains("props.required"))
        {
            form_fields.push(path.clone());
        }
        if Regex::new(r"useState.*sort|setSortKey|setSortDir|setSortOrder")?.is_match(&content)
            && Regex::new(r"<table|<Table|<th|<thead")?.is_match(&content)
        {
            sortable_tables.push(path.clone());
        }
        let normalized = path.to_string_lossy().replace('\\', "/");
        if (normalized.contains("/hooks/")
            || path
                .file_name()
                .and_then(|value| value.to_str())
                .is_some_and(|name| name.starts_with("use")))
            && Regex::new(r"useQuery|useSWR|useInfiniteQuery")?.is_match(&content)
            && Regex::new(r"isLoading|loading.*error|refetch|data.*error")?.is_match(&content)
        {
            query_hooks.push(path.clone());
        }
        for captures in style.captures_iter(&content) {
            styles
                .entry(captures[1].to_string())
                .or_default()
                .insert(path.clone());
        }
    }
    let mut findings = Vec::new();
    if form_fields.len() >= 3 {
        findings.push(group_finding(
            context,
            "TS-13",
            "FormField-like pattern",
            &form_fields,
        ));
    }
    if sortable_tables.len() >= 2 {
        findings.push(group_finding(
            context,
            "TS-13",
            "Sortable table pattern",
            &sortable_tables,
        ));
    }
    if query_hooks.len() >= 4 {
        findings.push(group_finding(
            context,
            "TS-13",
            "Query hook template pattern",
            &query_hooks,
        ));
    }
    for (value, paths) in styles {
        if paths.len() >= 2 {
            findings.push(Finding {
                rule: "TS-13",
                path: paths
                    .iter()
                    .next()
                    .cloned()
                    .unwrap_or_else(|| context.target.clone()),
                line: 1,
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
    output: &mut BTreeMap<String, BTreeSet<std::path::PathBuf>>,
) {
    for captures in pattern.captures_iter(content) {
        output
            .entry(captures[1].to_string())
            .or_default()
            .insert(path.to_path_buf());
    }
}

fn duplicate_name_findings(
    rule: &'static str,
    definitions: BTreeMap<String, BTreeSet<std::path::PathBuf>>,
    threshold: usize,
) -> Vec<Finding> {
    definitions
        .into_iter()
        .filter(|(_, paths)| paths.len() >= threshold)
        .map(|(name, paths)| Finding {
            rule,
            path: paths.iter().next().cloned().unwrap_or_default(),
            line: 1,
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
        .collect()
}

fn group_finding(
    context: &ScanContext,
    rule: &'static str,
    label: &str,
    paths: &[std::path::PathBuf],
) -> Finding {
    Finding {
        rule,
        path: paths
            .first()
            .cloned()
            .unwrap_or_else(|| context.target.clone()),
        line: 1,
        message: format!(
            "{label} found in {} files: {}",
            paths.len(),
            paths
                .iter()
                .map(|path| path.display().to_string())
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

fn production_files(context: &ScanContext) -> Vec<std::path::PathBuf> {
    context
        .files_with_extensions(&["ts", "tsx", "js", "jsx"])
        .into_iter()
        .filter(|path| !is_typescript_test_path(path))
        .collect()
}

fn is_cli_project(target: &Path) -> bool {
    let package = target.join("package.json");
    if let Ok(content) = std::fs::read_to_string(package) {
        if content.contains("\"bin\"")
            || Regex::new(r#""[^"]+"\s*:\s*"[^"]*cli[^"]*""#)
                .expect("valid CLI regex")
                .is_match(&content)
        {
            return true;
        }
    }
    ["ts", "tsx", "js", "jsx"].iter().any(|extension| {
        target.join(format!("src/cli.{extension}")).exists()
            || target.join(format!("cli.{extension}")).exists()
    })
}

fn has_any_type_annotation(line: &str, annotation: &Regex) -> bool {
    annotation.find_iter(line).any(|found| {
        let prefix = &line[..found.start()];
        let suffix = line[found.end()..].trim_start();
        let looks_like_object_value = matches!(suffix.chars().next(), Some(',' | '}'))
            && prefix.rfind('{').is_some_and(|brace| {
                let before_brace = prefix[..brace].trim_end();
                let declaration = before_brace.trim_start();
                !declaration.starts_with("type ")
                    && !declaration.starts_with("interface ")
                    && (before_brace.ends_with('=')
                        || before_brace.ends_with('(')
                        || before_brace.ends_with('[')
                        || before_brace.ends_with(',')
                        || before_brace.ends_with("=>")
                        || before_brace
                            .split_whitespace()
                            .next_back()
                            .is_some_and(|word| word == "return"))
            });
        !looks_like_object_value
    })
}
