use regex::Regex;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use super::rust::{mask_rust_non_code, strip_rust_comments};
use super::shared::{
    Finding, Result, ScanContext, ScanResult, is_rust_test_path, resolve_rust_type_path,
    rust_file_module,
};

pub(super) fn duplicate_types(context: &ScanContext) -> Result<ScanResult> {
    let definition = Regex::new(r"^\s*pub\s+(?:struct|enum)\s+([A-Za-z_][A-Za-z0-9_]*)")?;
    let allowlist_path = context.target.join(".vibeguard-duplicate-types-allowlist");
    let allowlist = context.current_allowlist(&allowlist_path)?;
    let previous_allowlist = context.previous_allowlist(&allowlist_path)?;
    let mut definitions: BTreeMap<String, Vec<(PathBuf, usize)>> = BTreeMap::new();
    for path in all_rust_files(context) {
        let content = context.read(&path)?;
        let masked = mask_rust_non_code(&content);
        for (index, line) in masked.lines().enumerate() {
            if let Some(captures) = definition.captures(line) {
                definitions
                    .entry(captures[1].to_string())
                    .or_default()
                    .push((path.clone(), index + 1));
            }
        }
    }
    let findings = definitions
        .into_iter()
        .filter_map(|(name, locations)| {
            if allowlist.contains(&name)
                || locations
                    .iter()
                    .map(|(path, _)| path)
                    .collect::<BTreeSet<_>>()
                    .len()
                    <= 1
            {
                return None;
            }
            let changed = locations
                .iter()
                .find(|(path, line)| context.allows_line(path, *line))
                .map(|(path, line)| (path.clone(), *line))
                .or_else(|| {
                    (previous_allowlist.contains(&name) && !allowlist.contains(&name))
                        .then(|| (allowlist_path.clone(), 1))
                })?;
            Some(Finding {
                rule: "RS-05",
                path: changed.0,
                line: changed.1,
                message: format!(
                    "Duplicate type: {name}; locations: {}",
                    locations
                        .iter()
                        .map(|(path, line)| format!("{}:{line}", path.display()))
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            })
        })
        .collect();
    Ok(ScanResult::new(
        findings,
        "No duplicate types found.",
        "Found {count} duplicate type(s).",
        &["Repair: extract the shared type or rename types with different semantics."],
    ))
}

pub(super) fn workspace_consistency(context: &ScanContext) -> Result<ScanResult> {
    let cargo_path = context.target.join("Cargo.toml");
    let cargo = match context.read(&cargo_path) {
        Ok(cargo) => cargo,
        Err(_error) if !cargo_path.exists() => {
            return Ok(ScanResult::new(
                Vec::new(),
                format!("Not a Cargo workspace: {} not found.", cargo_path.display()),
                "",
                &[],
            ));
        }
        Err(error) => {
            return Err(format!("cannot read {}: {error}", cargo_path.display()).into());
        }
    };
    if !cargo
        .lines()
        .any(|line| line.split('#').next().unwrap_or("").trim() == "[workspace]")
        && !cargo.contains("workspace.members")
    {
        return Ok(ScanResult::new(
            Vec::new(),
            "Not a Cargo workspace (no [workspace] section). Skipping.",
            "",
            &[],
        ));
    }
    let members = workspace_members(&context.target, &cargo)?;
    let workspace_changed =
        (1..=cargo.lines().count()).any(|line| context.allows_line(&cargo_path, line));
    let env_regex = Regex::new(r#"(?:env::var|env::var_os|option_env!)\s*\(\s*"([^"]+)""#)?;
    let db_regex = Regex::new(r#""([^"]*\.(?:db|sqlite))""#)?;
    let named_constant = Regex::new(r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:const|static)\b")?;
    let mut semantic_vars: BTreeMap<&str, BTreeSet<String>> = BTreeMap::new();
    let mut semantic_changed = BTreeSet::new();
    let mut db_files = BTreeSet::new();
    let mut db_changed = false;
    for member in members {
        let src = context.target.join(member).join("src");
        for path in walk_rust(&src)? {
            let content = context.read(&path)?;
            let comment_free = strip_rust_comments(&content);
            for (index, code) in comment_free.lines().enumerate() {
                for captures in env_regex.captures_iter(code) {
                    let name = captures[1].to_string();
                    let lower = name.to_ascii_lowercase();
                    let group = if lower.contains("db")
                        || lower.contains("database")
                        || lower.contains("sqlite")
                        || lower.contains("storage")
                    {
                        Some("database")
                    } else if lower.contains("port") || lower.contains("listen") {
                        Some("port")
                    } else if lower.contains("host")
                        || lower.contains("addr")
                        || lower.contains("bind")
                        || lower.contains("url")
                    {
                        Some("host")
                    } else {
                        None
                    };
                    if let Some(group) = group {
                        semantic_vars.entry(group).or_default().insert(name);
                        if context.allows_line(&path, index + 1) {
                            semantic_changed.insert(group);
                        }
                    }
                }
                if named_constant.is_match(code) {
                    continue;
                }
                for captures in db_regex.captures_iter(code) {
                    db_files.insert(captures[1].to_string());
                    db_changed |= context.allows_line(&path, index + 1);
                }
            }
        }
    }
    let mut findings = Vec::new();
    for (group, values) in semantic_vars {
        if values.len() > 1 && (workspace_changed || semantic_changed.contains(group)) {
            findings.push(Finding {
                rule: "RS-06",
                path: cargo_path.clone(),
                line: 1,
                message: format!(
                    "Multiple {group}-related env vars detected: {}",
                    values.into_iter().collect::<Vec<_>>().join(", ")
                ),
            });
        }
    }
    if db_files.len() > 1 && (workspace_changed || db_changed) {
        findings.push(Finding {
            rule: "RS-06",
            path: cargo_path,
            line: 1,
            message: format!(
                "Multiple database file names detected across members: {}",
                db_files.into_iter().collect::<Vec<_>>().join(", ")
            ),
        });
    }
    Ok(ScanResult::new(
        findings,
        "No cross-entry consistency issues detected.",
        "Found {count} potential consistency issue(s).",
        &["Repair: centralize configuration and data-path resolution in a shared crate."],
    ))
}

pub(super) fn single_source_of_truth(context: &ScanContext) -> Result<ScanResult> {
    let todo = Regex::new(r"\b(?:TodoWrite|TodoRead)\b")?;
    let task = Regex::new(
        r"\b(?:ViewTasks?|AddTask|UpdateTask|ReorganizeTasks?|TaskDone|TaskList|TaskManagement)\b",
    )?;
    let static_store = Regex::new(r"(?i)\bstatic\s+([A-Za-z_][A-Za-z0-9_]*)")?;
    let field_store = Regex::new(
        r"(?i)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?:Arc<)?(?:Mutex|RwLock|DashMap|HashMap|BTreeMap|Vec)",
    )?;
    let mut has_todo = false;
    let mut has_task = false;
    let mut family_changed = false;
    let mut stores = BTreeSet::new();
    for path in rust_files(context) {
        let content = context.read(&path)?;
        let masked = mask_rust_non_code(&content);
        for (index, line) in masked.lines().enumerate() {
            let line_changed = context.allows_line(&path, index + 1);
            if todo.is_match(line) {
                has_todo = true;
                family_changed |= line_changed;
            }
            if task.is_match(line) {
                has_task = true;
                family_changed |= line_changed;
            }
            let lower = line.to_ascii_lowercase();
            if !lower.contains("task") && !lower.contains("todo") {
                continue;
            }
            if let Some(captures) = static_store.captures(line) {
                stores.insert((path.clone(), index + 1, captures[1].to_string()));
            } else if let Some(captures) = field_store.captures(line) {
                stores.insert((path.clone(), index + 1, captures[1].to_string()));
            }
        }
    }
    let mut findings = Vec::new();
    if has_todo && has_task && family_changed {
        findings.push(structural(
            context,
            "RS-12",
            "Potential dual task systems detected (Todo* + TaskManagement*).",
        ));
    }
    if stores.len() > 1
        && stores
            .iter()
            .any(|(path, line, _)| context.allows_line(path, *line))
    {
        findings.push(structural(
            context,
            "RS-12",
            &format!(
                "Multiple task/todo state stores detected ({}): {}",
                stores.len(),
                stores
                    .into_iter()
                    .map(|(path, line, name)| format!("{name} at {}:{line}", path.display()))
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        ));
    }
    Ok(ScanResult::new(
        findings,
        "No single-source-of-truth issues detected.",
        "Found {count} potential single-source-of-truth issue(s).",
        &["Repair: converge on one tool family and one state repository."],
    ))
}

pub(super) fn semantic_effect(context: &ScanContext) -> Result<ScanResult> {
    let allowlist_path = context.target.join(".vibeguard-semantic-effect-allowlist");
    let allowlist = context.current_allowlist(&allowlist_path)?;
    let previous_allowlist = context.previous_allowlist(&allowlist_path)?;
    let function = Regex::new(r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)")?;
    let effect = Regex::new(
        r"\.(?:insert|push|remove|retain|update|replace|set)\s*\(|::(?:insert|push|remove|update|set|replace|write)\s*\(|\b(?:write|save|commit|emit|publish|dispatch|send|persist)\b",
    )?;
    let result = Regex::new(r"(?:Ok\(|Err\(|format!\(|json!\(|to_string\()")?;
    let mut findings = Vec::new();
    for path in rust_files(context) {
        let lower_path = path.to_string_lossy().to_ascii_lowercase();
        if !["task", "todo", "tool", "command"]
            .iter()
            .any(|part| lower_path.contains(part))
        {
            continue;
        }
        let content = context.read(&path)?;
        let masked = mask_rust_non_code(&content);
        let lines = masked.lines().collect::<Vec<_>>();
        let mut index = 0;
        let mut current = Vec::new();
        while index < lines.len() {
            let Some(captures) = function.captures(lines[index]) else {
                index += 1;
                continue;
            };
            let name = captures[1].to_string();
            if !action_name(&name) || allowlist.contains(&name) {
                index += 1;
                continue;
            }
            let start = index;
            let mut depth = 0isize;
            let mut entered = false;
            let mut bodyless = false;
            let mut body = String::new();
            while index < lines.len() {
                body.push_str(lines[index]);
                body.push('\n');
                let delta = lines[index].matches('{').count() as isize
                    - lines[index].matches('}').count() as isize;
                entered |= lines[index].contains('{');
                if !entered
                    && lines[index].trim_end().ends_with(';')
                    && body.matches('[').count() == body.matches(']').count()
                {
                    bodyless = true;
                }
                depth += delta;
                index += 1;
                if bodyless || entered && depth <= 0 {
                    break;
                }
            }
            let changed = (start + 1..=index).any(|line| context.allows_line(&path, line));
            let deleted_effect = context.has_deleted_between(&path, start + 1, index, &effect);
            if !bodyless
                && !effect.is_match(&body)
                && result.is_match(&body)
                && (changed || deleted_effect || previous_allowlist.contains(&name))
            {
                current.push(Finding {
                    rule: "RS-13",
                    path: path.clone(),
                    line: start + 1,
                    message: format!("action-like function '{name}' has no visible side effect"),
                });
            }
        }
        findings.extend(context.keep_unsuppressed(&content, current));
    }
    Ok(ScanResult::new(
        findings,
        "No semantic-effect mismatches detected.",
        "[RS-13] Found {count} action-like function(s) without visible side-effects:",
        &[
            "Repair: perform the promised state write/event emission, or rename a query-only function.",
        ],
    ))
}

pub(super) fn declaration_execution_gap(context: &ScanContext) -> Result<ScanResult> {
    let default_call = Regex::new(
        r"(?s)((?:[A-Za-z_][A-Za-z0-9_]*\s*::\s*)*[A-Za-z_][A-Za-z0-9_]*Config)(?:\s*::\s*<[^;{}]+>)?\s*::\s*default\s*\(",
    )?;
    let method = Regex::new(r"\bfn\s+(load|save|persist|restore)\s*\(")?;
    let mut type_methods: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut declarations = Vec::new();
    let mut sources = Vec::new();
    for path in all_rust_files(context) {
        let content = context.read(&path)?;
        let masked = mask_rust_non_code(&content);
        for block in impl_blocks(&masked, &path, &context.target)? {
            for captures in method.captures_iter(&masked[block.body_start..block.body_end]) {
                let method_name = captures[1].to_string();
                let line = 1 + masked.as_bytes()
                    [..block.body_start + captures.get(0).map_or(0, |matched| matched.start())]
                    .iter()
                    .filter(|byte| **byte == b'\n')
                    .count();
                type_methods
                    .entry(block.identity.clone())
                    .or_default()
                    .insert(method_name.clone());
                declarations.push((path.clone(), line, block.bare.clone(), method_name));
            }
        }
        sources.push((path, content, masked));
    }
    let startup = sources
        .iter()
        .filter(|(path, _, _)| startup_path(path))
        .map(|(_, _, masked)| masked.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    let mut findings = Vec::new();
    for (path, content, masked) in &sources {
        let mut current = Vec::new();
        for captures in default_call.captures_iter(masked) {
            let Some(found) = captures.get(0) else {
                continue;
            };
            let line = masked.as_bytes()[..found.start()]
                .iter()
                .filter(|byte| **byte == b'\n')
                .count()
                + 1;
            let end_line = line + found.as_str().matches('\n').count();
            let full = resolve_rust_type_path(&captures[1], path, &context.target);
            if (line..=end_line).any(|candidate| context.allows_line(path, candidate))
                && resolves_to_load(&type_methods, path, &context.target, &full)
            {
                current.push(Finding {
                    rule: "RS-14",
                    path: path.clone(),
                    line,
                    message: format!("Config::default() bypasses load() ({})", &captures[0]),
                });
            }
        }
        findings.extend(context.keep_unsuppressed(content, current));
    }
    for (path, line, type_name, method_name) in declarations {
        let call = Regex::new(&format!(
            r"(?:{}\s*::|\.)\s*{}\s*\(",
            regex::escape(&type_name),
            regex::escape(&method_name)
        ))?;
        let deleted_call = sources
            .iter()
            .any(|(source, _, _)| startup_path(source) && context.has_deleted_match(source, &call));
        if (context.allows_line(&path, line) || deleted_call) && !call.is_match(&startup) {
            let finding = Finding {
                rule: "RS-14",
                path: path.clone(),
                line,
                message: format!(
                    "Persistence method '{type_name}::{method_name}()' is declared but not called at startup"
                ),
            };
            let Some((_, content, _)) = sources.iter().find(|(source, _, _)| source == &path)
            else {
                return Err(
                    format!("persistence declaration source missing: {}", path.display()).into(),
                );
            };
            findings.extend(context.keep_unsuppressed(content, vec![finding]));
        }
    }
    Ok(ScanResult::new(
        findings,
        "[RS-14] PASS: Config statement-execution gap not detected",
        "Found {count} potential Config declaration-execution gap(s).",
        &["Repair: call Config::load()/persistence methods from the startup path."],
    ))
}

fn rust_files(context: &ScanContext) -> Vec<PathBuf> {
    context
        .files_with_extensions(&["rs"])
        .into_iter()
        .filter(|path| !is_rust_test_path(path))
        .collect()
}

fn all_rust_files(context: &ScanContext) -> Vec<PathBuf> {
    context
        .all_files_with_extensions(&["rs"])
        .into_iter()
        .filter(|path| !is_rust_test_path(path))
        .collect()
}

struct ImplBlock {
    identity: String,
    bare: String,
    body_start: usize,
    body_end: usize,
}

fn impl_blocks(masked: &str, path: &Path, target: &Path) -> Result<Vec<ImplBlock>> {
    let keyword = Regex::new(r"\bimpl\b")?;
    let mut blocks = Vec::new();
    for found in keyword.find_iter(masked) {
        let Some(open) = impl_open_brace(masked, found.end()) else {
            continue;
        };
        let Some(close) = matching_brace(masked, open) else {
            continue;
        };
        let Some(raw_type) = impl_target(&masked[found.end()..open]) else {
            continue;
        };
        let normalized = resolve_rust_type_path(raw_type, path, target);
        let bare = normalized
            .rsplit("::")
            .next()
            .unwrap_or(&normalized)
            .to_string();
        let identity = if normalized.contains("::") {
            normalized
        } else if let Some(module) = rust_file_module(path, target) {
            format!("{module}::{bare}")
        } else {
            bare.clone()
        };
        blocks.push(ImplBlock {
            identity,
            bare,
            body_start: open + 1,
            body_end: close,
        });
    }
    Ok(blocks)
}

fn impl_open_brace(source: &str, start: usize) -> Option<usize> {
    let mut angles = 0isize;
    for (offset, character) in source[start..].char_indices() {
        match character {
            '<' => angles += 1,
            '>' => angles = angles.saturating_sub(1),
            '{' if angles == 0 => return Some(start + offset),
            ';' if angles == 0 => return None,
            _ => {}
        }
    }
    None
}

fn matching_brace(source: &str, open: usize) -> Option<usize> {
    let mut depth = 0isize;
    for (offset, character) in source[open..].char_indices() {
        match character {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(open + offset);
                }
            }
            _ => {}
        }
    }
    None
}

fn impl_target(header: &str) -> Option<&str> {
    let header = header.trim_start();
    let header = if header.starts_with('<') {
        let end = balanced_angle_end(header)?;
        header[end..].trim_start()
    } else {
        header
    };
    let header = header.trim();
    let target = top_level_for(header).map_or(header, |index| &header[index + 3..]);
    let target = target.trim_start();
    let end = target
        .char_indices()
        .take_while(|(_, character)| {
            character.is_ascii_alphanumeric() || matches!(character, '_' | ':')
        })
        .map(|(index, character)| index + character.len_utf8())
        .last()?;
    Some(&target[..end])
}

fn balanced_angle_end(value: &str) -> Option<usize> {
    let mut depth = 0isize;
    for (index, character) in value.char_indices() {
        match character {
            '<' => depth += 1,
            '>' => {
                depth -= 1;
                if depth == 0 {
                    return Some(index + 1);
                }
            }
            _ => {}
        }
    }
    None
}

fn top_level_for(value: &str) -> Option<usize> {
    let mut depth = 0isize;
    for (index, character) in value.char_indices() {
        match character {
            '<' => depth += 1,
            '>' => depth = depth.saturating_sub(1),
            'f' if depth == 0 && value[index..].starts_with("for ") => return Some(index),
            _ => {}
        }
    }
    None
}

fn resolves_to_load(
    methods: &BTreeMap<String, BTreeSet<String>>,
    path: &Path,
    target: &Path,
    requested: &str,
) -> bool {
    if requested.contains("::") {
        return methods
            .get(requested)
            .is_some_and(|values| values.contains("load"));
    }
    if let Some(module) = rust_file_module(path, target)
        && methods
            .get(&format!("{module}::{requested}"))
            .is_some_and(|values| values.contains("load"))
    {
        return true;
    }
    let matches = methods
        .iter()
        .filter(|(identity, values)| {
            identity.rsplit("::").next() == Some(requested) && values.contains("load")
        })
        .count();
    matches == 1
}

fn workspace_members(root: &Path, cargo: &str) -> Result<Vec<PathBuf>> {
    let quoted = Regex::new(r#""([^"]+)""#).expect("valid member regex");
    let mut in_members = false;
    let mut patterns = Vec::new();
    for line in cargo.lines() {
        let line = line.split('#').next().unwrap_or("");
        if line.contains("members") && line.contains('=') {
            in_members = true;
        }
        if in_members {
            for captures in quoted.captures_iter(line) {
                patterns.push(captures[1].to_string());
            }
            if line.contains(']') {
                in_members = false;
            }
        }
    }
    let mut members = BTreeSet::new();
    let mut available = Vec::new();
    if patterns
        .iter()
        .any(|pattern| pattern.contains(['*', '?', '[']))
    {
        collect_manifest_dirs(root, root, &mut available)?;
    }
    for pattern in patterns {
        if pattern.contains(['*', '?', '[']) {
            members.extend(
                available
                    .iter()
                    .filter(|member| path_glob_matches(&pattern, member))
                    .cloned(),
            );
        } else {
            members.insert(PathBuf::from(pattern));
        }
    }
    Ok(members.into_iter().collect())
}

fn collect_manifest_dirs(root: &Path, path: &Path, output: &mut Vec<PathBuf>) -> Result<()> {
    let entries = fs::read_dir(path).map_err(|error| {
        format!(
            "cannot read workspace directory {}: {error}",
            path.display()
        )
    })?;
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            let name = entry.file_name();
            if matches!(name.to_str(), Some(".git" | "target" | "node_modules")) {
                continue;
            }
            if path.join("Cargo.toml").is_file() {
                output.push(path.strip_prefix(root)?.to_path_buf());
            }
            collect_manifest_dirs(root, &path, output)?;
        }
    }
    Ok(())
}

fn path_glob_matches(pattern: &str, path: &Path) -> bool {
    let pattern = pattern.replace('\\', "/");
    let path = path.to_string_lossy().replace('\\', "/");
    let pattern_parts = pattern.split('/').collect::<Vec<_>>();
    let path_parts = path.split('/').collect::<Vec<_>>();
    pattern_parts.len() == path_parts.len()
        && pattern_parts
            .iter()
            .zip(path_parts)
            .all(|(pattern, value)| glob_segment_matches(pattern, value))
}

fn glob_segment_matches(pattern: &str, value: &str) -> bool {
    fn matches(pattern: &[char], value: &[char]) -> bool {
        match pattern.split_first() {
            None => value.is_empty(),
            Some(('*', rest)) => {
                matches(rest, value)
                    || value
                        .split_first()
                        .is_some_and(|(_, tail)| matches(pattern, tail))
            }
            Some(('?', rest)) => value
                .split_first()
                .is_some_and(|(_, tail)| matches(rest, tail)),
            Some(('[', rest)) => {
                let Some(close) = rest.iter().position(|character| *character == ']') else {
                    return value
                        .split_first()
                        .is_some_and(|(actual, tail)| *actual == '[' && matches(rest, tail));
                };
                let (class, suffix) = rest.split_at(close);
                let Some((character, tail)) = value.split_first() else {
                    return false;
                };
                let negated = matches!(class.first(), Some('!' | '^'));
                let class = if negated { &class[1..] } else { class };
                let mut class_match = false;
                let mut index = 0;
                while index < class.len() {
                    if index + 2 < class.len() && class[index + 1] == '-' {
                        class_match |= class[index] <= *character && *character <= class[index + 2];
                        index += 3;
                    } else {
                        class_match |= class[index] == *character;
                        index += 1;
                    }
                }
                (class_match != negated) && matches(&suffix[1..], tail)
            }
            Some((expected, rest)) => value
                .split_first()
                .is_some_and(|(actual, tail)| expected == actual && matches(rest, tail)),
        }
    }
    matches(
        &pattern.chars().collect::<Vec<_>>(),
        &value.chars().collect::<Vec<_>>(),
    )
}

fn walk_rust(root: &Path) -> Result<Vec<PathBuf>> {
    fn visit(path: &Path, output: &mut Vec<PathBuf>) -> Result<()> {
        let entries = match fs::read_dir(path) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => {
                return Err(
                    format!("cannot read source directory {}: {error}", path.display()).into(),
                );
            }
        };
        for entry in entries {
            let entry = entry?;
            let path = entry.path();
            let file_type = entry.file_type()?;
            if file_type.is_dir() {
                visit(&path, output)?;
            } else if file_type.is_file()
                && path.extension().and_then(|value| value.to_str()) == Some("rs")
            {
                output.push(path);
            }
        }
        Ok(())
    }
    let mut output = Vec::new();
    visit(root, &mut output)?;
    Ok(output)
}

fn structural(context: &ScanContext, rule: &'static str, message: &str) -> Finding {
    Finding {
        rule,
        path: context.target.clone(),
        line: 1,
        message: message.to_string(),
    }
}

fn action_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    lower == "done"
        || lower == "mark_done"
        || lower.ends_with("_done")
        || ["update_", "delete_", "remove_", "add_", "create_", "set_"]
            .iter()
            .any(|prefix| lower.starts_with(prefix))
        || ((lower.starts_with("task") || lower.starts_with("todo"))
            && ["done", "update", "delete", "remove", "add", "create"]
                .iter()
                .any(|suffix| lower.ends_with(suffix)))
}

fn startup_path(path: &Path) -> bool {
    let normalized = path.to_string_lossy().replace('\\', "/");
    let basename = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("");
    matches!(basename, "main.rs" | "lib.rs") || normalized.contains("/bin/")
}
