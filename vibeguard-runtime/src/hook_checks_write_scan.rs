use regex::Regex;
use std::fs;
use std::path::{Path, PathBuf};

use crate::hook_checks_common::is_test_path;
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

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ProjectScanWithSameName {
    pub(crate) project: ProjectScan,
    pub(crate) same_name: SameNameScan,
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
        None,
    );
    ProjectScan {
        files,
        count,
        degraded,
        incomplete,
    }
}

#[cfg(test)]
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

pub(crate) fn scan_project_files_with_same_name(
    project_dir: &Path,
    file_path: &str,
    max_files: usize,
    max_matches: usize,
) -> ProjectScanWithSameName {
    let mut files = Vec::new();
    let mut count = 0usize;
    let mut incomplete = false;
    let mut same_name = SameNameCollector::new(file_path, max_matches);
    let degraded = scan_dir(
        project_dir,
        max_files,
        Some(&mut files),
        &mut count,
        &mut incomplete,
        Some(&mut same_name),
    );
    ProjectScanWithSameName {
        project: ProjectScan {
            files,
            count,
            degraded,
            incomplete,
        },
        same_name: SameNameScan {
            matches: same_name.matches,
            incomplete,
        },
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
    duplicate_definition_scan_with_reader(
        files,
        file_path,
        content,
        ext,
        max_scan_defs,
        max_matches,
        |path| fs::read_to_string(path),
    )
}

fn duplicate_definition_scan_with_reader<F>(
    files: &[PathBuf],
    file_path: &str,
    content: &str,
    ext: &str,
    max_scan_defs: usize,
    max_matches: usize,
    mut read_file: F,
) -> DefinitionScan
where
    F: FnMut(&Path) -> std::io::Result<String>,
{
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

    let per_definition_limit = max_matches.min(3);
    let mut incomplete = false;
    let mut matchers = Vec::new();
    for defname in definitions {
        match duplicate_definition_regex(&defname) {
            Ok(regex) => matchers.push((defname, regex, Vec::<String>::new())),
            Err(_) => incomplete = true,
        }
    }
    if matchers.is_empty() || per_definition_limit == 0 {
        return DefinitionScan {
            duplicates: Vec::new(),
            incomplete,
        };
    }

    let target = absolute_path(file_path);
    for path in files {
        if matchers
            .iter()
            .all(|(_, _, matches)| matches.len() >= per_definition_limit)
        {
            break;
        }
        if path.extension().and_then(|s| s.to_str()) != Some(ext) {
            continue;
        }
        if absolute_path(path.to_string_lossy().as_ref()) == target {
            continue;
        }
        let Ok(text) = read_file(path) else {
            incomplete = true;
            continue;
        };
        let path_display = path.to_string_lossy().into_owned();
        for (_, regex, matches) in &mut matchers {
            if matches.len() >= per_definition_limit {
                continue;
            }
            if regex.is_match(&text) {
                matches.push(path_display.clone());
            }
        }
    }

    let duplicates = matchers
        .into_iter()
        .filter_map(|(defname, _, matches)| {
            (!matches.is_empty()).then(|| format!("{defname}(in {})", matches.join(", ")))
        })
        .collect();
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
    mut same_name: Option<&mut SameNameCollector>,
) -> bool {
    let Ok(entries) = fs::read_dir(dir) else {
        *incomplete = true;
        return false;
    };
    let mut degraded = false;
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
            if scan_dir(
                &path,
                max_files,
                child_files,
                count,
                incomplete,
                same_name.as_deref_mut(),
            ) {
                degraded = true;
                if same_name
                    .as_ref()
                    .is_none_or(|collector| collector.is_saturated())
                {
                    return true;
                }
            }
        } else if file_type.is_file() {
            *count += 1;
            if let Some(collector) = same_name.as_deref_mut() {
                collector.visit(&path);
            }
            if *count > max_files {
                degraded = true;
            } else if let Some(files) = files.as_deref_mut() {
                files.push(path);
            }
            if degraded
                && same_name
                    .as_ref()
                    .is_none_or(|collector| collector.is_saturated())
            {
                return true;
            }
        }
    }
    degraded
}

#[cfg(test)]
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
                && !is_test_path(path.to_string_lossy().as_ref())
            {
                matches.push(path.to_string_lossy().into_owned());
            }
        }
    }
}

struct SameNameCollector {
    basename: Option<String>,
    target: PathBuf,
    max_matches: usize,
    matches: Vec<String>,
}

impl SameNameCollector {
    fn new(file_path: &str, max_matches: usize) -> Self {
        Self {
            basename: Path::new(file_path)
                .file_name()
                .and_then(|s| s.to_str())
                .map(ToOwned::to_owned),
            target: absolute_path(file_path),
            max_matches,
            matches: Vec::new(),
        }
    }

    fn is_saturated(&self) -> bool {
        self.matches.len() >= self.max_matches
    }

    fn visit(&mut self, path: &Path) {
        if self.is_saturated() {
            return;
        }
        let Some(basename) = self.basename.as_deref() else {
            return;
        };
        if path.file_name().and_then(|s| s.to_str()) == Some(basename)
            && absolute_path(path.to_string_lossy().as_ref()) != self.target
            && !is_test_path(path.to_string_lossy().as_ref())
        {
            self.matches.push(path.to_string_lossy().into_owned());
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
