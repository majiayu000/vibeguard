use regex::Regex;
use std::fs;
use std::path::{Path, PathBuf};

use crate::hook_checks_scan::absolute_path;

const SKIP_DIRS: &[&str] = &[
    "node_modules",
    ".git",
    "target",
    "vendor",
    "dist",
    "build",
    "__pycache__",
    ".venv",
    "tests",
    "__tests__",
    "test",
    "spec",
];
const IGNORED_DEFINITION_NAMES: &[&str] = &[
    "self", "init", "main", "test", "None", "True", "False", "this", "super", "impl", "type",
    "move", "async",
];

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ProjectScan {
    pub(crate) files: Vec<PathBuf>,
    pub(crate) count: usize,
    pub(crate) degraded: bool,
    pub(crate) incomplete: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct SameNameScan {
    pub(crate) matches: Vec<String>,
    pub(crate) incomplete: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct DefinitionScan {
    pub(crate) duplicates: Vec<String>,
    pub(crate) incomplete: bool,
}

pub(crate) fn scan_project_files(project_dir: &Path, max_files: usize) -> ProjectScan {
    let mut files = Vec::new();
    let mut count = 0usize;
    let mut incomplete = false;
    let degraded = scan_dir(
        project_dir,
        max_files,
        Some(&mut files),
        &mut count,
        &mut incomplete,
    );
    ProjectScan {
        files,
        count,
        degraded,
        incomplete,
    }
}

pub(crate) fn scan_same_name_matches(
    project_dir: &Path,
    file_path: &str,
    max_matches: usize,
) -> SameNameScan {
    let Some(basename) = Path::new(file_path).file_name().and_then(|s| s.to_str()) else {
        return SameNameScan {
            matches: Vec::new(),
            incomplete: false,
        };
    };
    let target = absolute_path(file_path);
    let mut count = 0usize;
    let mut incomplete = false;
    let mut matches = Vec::new();
    scan_same_name_dir(
        project_dir,
        basename,
        &target,
        max_matches,
        &mut count,
        &mut incomplete,
        &mut matches,
    );
    SameNameScan {
        matches,
        incomplete,
    }
}

pub(crate) fn duplicate_definition_scan(
    files: &[PathBuf],
    file_path: &str,
    content: &str,
    ext: &str,
    max_scan_defs: usize,
    max_matches: usize,
) -> DefinitionScan {
    let definitions = extract_definitions(content, ext)
        .into_iter()
        .take(max_scan_defs)
        .collect::<Vec<_>>();
    if definitions.is_empty() {
        return DefinitionScan {
            duplicates: Vec::new(),
            incomplete: false,
        };
    }

    let target = absolute_path(file_path);
    let mut duplicates = Vec::new();
    let mut incomplete = false;
    for defname in definitions {
        let found = find_definition_matches(files, &target, ext, &defname, max_matches.min(3));
        incomplete |= found.incomplete;
        if !found.matches.is_empty() {
            duplicates.push(format!("{defname}(in {})", found.matches.join(", ")));
        }
    }
    DefinitionScan {
        duplicates,
        incomplete,
    }
}

fn scan_dir(
    dir: &Path,
    max_files: usize,
    mut files: Option<&mut Vec<PathBuf>>,
    count: &mut usize,
    incomplete: &mut bool,
) -> bool {
    let Ok(entries) = fs::read_dir(dir) else {
        *incomplete = true;
        return false;
    };
    for entry_result in entries {
        let Ok(entry) = entry_result else {
            *incomplete = true;
            continue;
        };
        let path = entry.path();
        let Ok(file_type) = entry.file_type() else {
            *incomplete = true;
            continue;
        };
        if file_type.is_dir() {
            if should_skip_dir(&path) {
                continue;
            }
            let child_files = files.as_deref_mut();
            if scan_dir(&path, max_files, child_files, count, incomplete) {
                return true;
            }
        } else if file_type.is_file() {
            *count += 1;
            if *count > max_files {
                return true;
            }
            if let Some(files) = files.as_deref_mut() {
                files.push(path);
            }
        }
    }
    false
}

fn scan_same_name_dir(
    dir: &Path,
    basename: &str,
    target: &Path,
    max_matches: usize,
    count: &mut usize,
    incomplete: &mut bool,
    matches: &mut Vec<String>,
) {
    if matches.len() >= max_matches {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        *incomplete = true;
        return;
    };
    for entry_result in entries {
        if matches.len() >= max_matches {
            break;
        }
        let Ok(entry) = entry_result else {
            *incomplete = true;
            continue;
        };
        let path = entry.path();
        let Ok(file_type) = entry.file_type() else {
            *incomplete = true;
            continue;
        };
        if file_type.is_dir() {
            if should_skip_dir(&path) {
                continue;
            }
            scan_same_name_dir(
                &path,
                basename,
                target,
                max_matches,
                count,
                incomplete,
                matches,
            );
        } else if file_type.is_file() {
            *count += 1;
            if path.file_name().and_then(|s| s.to_str()) == Some(basename)
                && absolute_path(path.to_string_lossy().as_ref()) != target
            {
                matches.push(path.to_string_lossy().into_owned());
            }
        }
    }
}

fn extract_definitions(content: &str, ext: &str) -> Vec<String> {
    let patterns = definition_patterns(ext);
    let mut names = Vec::new();
    for pattern in patterns {
        let Ok(regex) = Regex::new(pattern) else {
            continue;
        };
        for captures in regex.captures_iter(content) {
            let Some(name) = captures.get(1).map(|m| m.as_str()) else {
                continue;
            };
            if is_meaningful_definition_name(name) && !names.iter().any(|existing| existing == name)
            {
                names.push(name.to_string());
            }
        }
    }
    names.sort();
    names
}

fn definition_patterns(ext: &str) -> &'static [&'static str] {
    match ext {
        "rs" => &[
            r"(?:pub\s+(?:\w+\s+)?)?(?:struct|enum|trait|union)\s+(\w+)",
            r"(?:pub\s+(?:\w+\s+)?)?fn\s+(\w+)",
        ],
        "ts" | "tsx" | "js" | "jsx" => &[
            r"(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+(\w+)",
            r"(?:export\s+)?interface\s+(\w+)",
            r"(?:export\s+)?(?:async\s+)?function\s+(\w+)",
            r"(?:export\s+)?const\s+(\w+)\s*=\s*(?:async\s+)?\(",
        ],
        "py" => &[r"class\s+(\w+)", r"def\s+(\w+)\s*\("],
        "go" => &[
            r"type\s+(\w+)\s+(?:struct|interface)",
            r"func\s+(?:\([^)]+\)\s+)?(\w+)\s*\(",
        ],
        _ => &[
            r"(?:class|interface)\s+(\w+)",
            r"(?:function|func|def)\s+(\w+)",
        ],
    }
}

struct DefinitionMatchScan {
    matches: Vec<String>,
    incomplete: bool,
}

fn find_definition_matches(
    files: &[PathBuf],
    target: &Path,
    ext: &str,
    defname: &str,
    max_matches: usize,
) -> DefinitionMatchScan {
    let mut found = Vec::new();
    let Ok(regex) = duplicate_definition_regex(defname) else {
        return DefinitionMatchScan {
            matches: found,
            incomplete: true,
        };
    };
    let mut incomplete = false;
    for path in files {
        if found.len() >= max_matches {
            break;
        }
        if path.extension().and_then(|s| s.to_str()) != Some(ext) {
            continue;
        }
        if absolute_path(path.to_string_lossy().as_ref()) == target {
            continue;
        }
        let Ok(text) = fs::read_to_string(path) else {
            incomplete = true;
            continue;
        };
        if regex.is_match(&text) {
            found.push(path.to_string_lossy().into_owned());
        }
    }
    DefinitionMatchScan {
        matches: found,
        incomplete,
    }
}

fn duplicate_definition_regex(defname: &str) -> std::result::Result<Regex, regex::Error> {
    let name = regex::escape(defname);
    Regex::new(&format!(
        r"\b(?:struct|class|interface|type|fn|func|def|function)\s+{}\b",
        name
    ))
}

fn is_meaningful_definition_name(name: &str) -> bool {
    name.len() > 3 && !name.starts_with('_') && !IGNORED_DEFINITION_NAMES.contains(&name)
}

fn should_skip_dir(path: &Path) -> bool {
    path.file_name()
        .and_then(|s| s.to_str())
        .is_some_and(|name| SKIP_DIRS.contains(&name))
}

#[cfg(test)]
#[path = "hook_checks_write_scan_tests.rs"]
mod tests;
