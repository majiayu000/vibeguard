use regex::Regex;
use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

pub(super) type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

pub(super) fn rust_file_module(path: &Path, target: &Path) -> Option<String> {
    let relative = path.strip_prefix(target).unwrap_or(path);
    let components = relative
        .components()
        .map(|part| part.as_os_str())
        .collect::<Vec<_>>();
    let src = components.iter().rposition(|part| *part == "src")?;
    let mut modules = components[src + 1..components.len().saturating_sub(1)]
        .iter()
        .map(|part| part.to_string_lossy().to_string())
        .collect::<Vec<_>>();
    let stem = path.file_stem()?.to_string_lossy();
    if !matches!(stem.as_ref(), "lib" | "main" | "mod") {
        modules.push(stem.to_string());
    }
    (!modules.is_empty()).then(|| modules.join("::"))
}

pub(super) fn resolve_rust_type_path(value: &str, path: &Path, target: &Path) -> String {
    let normalized = value
        .split("::")
        .map(str::trim)
        .collect::<Vec<_>>()
        .join("::");
    let value = normalized.as_str();
    if let Some(value) = value.strip_prefix("crate::") {
        return value.to_string();
    }
    let mut modules = rust_file_module(path, target)
        .map(|module| module.split("::").map(str::to_string).collect::<Vec<_>>())
        .unwrap_or_default();
    let mut relative = value;
    if let Some(value) = relative.strip_prefix("self::") {
        relative = value;
    } else if !relative.starts_with("super::") {
        return relative.to_string();
    }
    while let Some(value) = relative.strip_prefix("super::") {
        modules.pop();
        relative = value;
    }
    modules.push(relative.to_string());
    modules.join("::")
}

#[derive(Debug)]
pub(super) struct ScanArgs {
    pub(super) language: String,
    pub(super) rule: String,
    pub(super) strict: bool,
    pub(super) baseline: Option<String>,
    pub(super) target: PathBuf,
}

impl ScanArgs {
    pub(super) fn parse(args: &[String]) -> Result<Self> {
        if args.len() < 2 {
            return Err("Usage: vibeguard-runtime scan <language> <rule> [--strict] [--baseline <commit>] [target-dir]".into());
        }
        let language = args[0].clone();
        let rule = args[1].clone();
        let mut strict = false;
        let mut baseline = None;
        let mut target = None;
        let mut index = 2;
        while index < args.len() {
            match args[index].as_str() {
                "--strict" => strict = true,
                "--baseline" => {
                    index += 1;
                    let value = args
                        .get(index)
                        .filter(|value| !value.is_empty())
                        .ok_or("Error: --baseline requires a commit argument")?;
                    baseline = Some(value.clone());
                }
                "--help" | "-h" => {
                    return Err("Usage: vibeguard-runtime scan <language> <rule> [--strict] [--baseline <commit>] [target-dir]".into());
                }
                value if value.starts_with("--") => {
                    return Err(format!("Unknown option: {value}").into());
                }
                value => {
                    if target.is_some() {
                        return Err(format!("Too many positional arguments: {value}").into());
                    }
                    target = Some(PathBuf::from(value));
                }
            }
            index += 1;
        }
        let target = target.unwrap_or_else(|| PathBuf::from("."));
        let target = fs::canonicalize(&target).map_err(|error| {
            format!(
                "cannot resolve target directory {}: {error}",
                target.display()
            )
        })?;
        if !target.is_dir() {
            return Err(format!("target is not a directory: {}", target.display()).into());
        }
        if let Some(commit) = baseline.as_deref() {
            let output = Command::new("git")
                .args(["-C"])
                .arg(&target)
                .args(["rev-parse", "--verify", commit])
                .output()?;
            if !output.status.success() {
                return Err(format!(
                    "Error: --baseline '{commit}' is not a valid commit in '{}'",
                    target.display()
                )
                .into());
            }
        }
        Ok(Self {
            language,
            rule,
            strict,
            baseline,
            target,
        })
    }
}

#[derive(Clone, Debug)]
pub(super) struct Finding {
    pub(super) rule: &'static str,
    pub(super) path: PathBuf,
    pub(super) line: usize,
    pub(super) message: String,
}

impl Finding {
    pub(super) fn render(&self) -> String {
        format!(
            "[{}] {}:{}: {}",
            self.rule,
            self.path.display(),
            self.line,
            self.message
        )
    }
}

pub(super) struct ScanResult {
    findings: Vec<Finding>,
    clean_message: String,
    finding_header: String,
    footer: Vec<String>,
}

impl ScanResult {
    pub(super) fn new(
        findings: Vec<Finding>,
        clean_message: impl Into<String>,
        finding_header: impl Into<String>,
        footer: &[&str],
    ) -> Self {
        Self {
            findings,
            clean_message: clean_message.into(),
            finding_header: finding_header.into(),
            footer: footer.iter().map(|line| (*line).to_string()).collect(),
        }
    }

    pub(super) fn has_findings(&self) -> bool {
        !self.findings.is_empty()
    }

    pub(super) fn print(&self) {
        if self.findings.is_empty() {
            println!("{}", self.clean_message);
            return;
        }
        println!(
            "{}",
            self.finding_header
                .replace("{count}", &self.findings.len().to_string())
        );
        for finding in &self.findings {
            println!("{}", finding.render());
        }
        if !self.footer.is_empty() {
            println!();
            for line in &self.footer {
                println!("{line}");
            }
        }
    }
}

#[derive(Default)]
struct DiffMap {
    added: BTreeMap<PathBuf, BTreeSet<usize>>,
    deleted: BTreeMap<PathBuf, Vec<(usize, String)>>,
    renames: BTreeMap<PathBuf, PathBuf>,
}

pub(super) struct ScanContext {
    pub(super) target: PathBuf,
    pub(super) language: String,
    rule: String,
    files: Vec<PathBuf>,
    all_files: Vec<PathBuf>,
    diff: Option<DiffMap>,
    staged: bool,
    git_root: Option<PathBuf>,
    baseline: Option<String>,
}

impl ScanContext {
    pub(super) fn new(args: &ScanArgs) -> Result<Self> {
        let staged_file = env::var_os("VIBEGUARD_STAGED_FILES")
            .map(PathBuf::from)
            .filter(|path| path.is_file());
        let staged = staged_file.is_some();
        let git_root = git_root(&args.target);
        let all_files = if let Some(root) = git_root.as_deref() {
            tracked_files(root, &args.target)?
        } else {
            walked_files(&args.target)?
        };
        let files = if let Some(path) = staged_file {
            read_staged_files(&path, &args.target)?
        } else {
            all_files.clone()
        };
        let diff = if staged || args.baseline.is_some() {
            let root = git_root
                .as_deref()
                .ok_or("diff scan requires a Git worktree")?;
            Some(build_diff_map(root, staged, args.baseline.as_deref())?)
        } else {
            None
        };
        Ok(Self {
            target: args.target.clone(),
            language: args.language.clone(),
            rule: args.rule.clone(),
            files,
            all_files,
            diff,
            staged,
            git_root,
            baseline: args.baseline.clone(),
        })
    }

    pub(super) fn files_with_extensions(&self, extensions: &[&str]) -> Vec<PathBuf> {
        self.files
            .iter()
            .filter(|path| {
                path.extension()
                    .and_then(|value| value.to_str())
                    .is_some_and(|value| extensions.contains(&value))
            })
            .cloned()
            .collect()
    }

    pub(super) fn all_files_with_extensions(&self, extensions: &[&str]) -> Vec<PathBuf> {
        self.all_files
            .iter()
            .filter(|path| {
                path.extension()
                    .and_then(|value| value.to_str())
                    .is_some_and(|value| extensions.contains(&value))
            })
            .cloned()
            .collect()
    }

    pub(super) fn read(&self, path: &Path) -> Result<String> {
        if self.staged
            && let (Some(root), Ok(relative)) = (
                self.git_root.as_deref(),
                path.strip_prefix(self.git_root.as_deref().unwrap_or(Path::new(""))),
            )
        {
            let output = Command::new("git")
                .args(["-C"])
                .arg(root)
                .args(["show", &format!(":{}", relative.to_string_lossy())])
                .output()?;
            if output.status.success() {
                return String::from_utf8(output.stdout)
                    .map_err(|error| format!("{} is not UTF-8: {error}", path.display()).into());
            }
        }
        fs::read_to_string(path)
            .map_err(|error| format!("cannot read {}: {error}", path.display()).into())
    }

    pub(super) fn allows_line(&self, path: &Path, line: usize) -> bool {
        let Some(diff) = &self.diff else {
            return true;
        };
        if let Some(old) = diff.renames.get(path)
            && path_enforcement_class(&self.language, &self.rule, &self.target, old)
                != path_enforcement_class(&self.language, &self.rule, &self.target, path)
        {
            return true;
        }
        diff.added
            .get(path)
            .is_some_and(|lines| lines.contains(&line))
    }

    pub(super) fn has_deleted_between(
        &self,
        path: &Path,
        start: usize,
        end: usize,
        pattern: &Regex,
    ) -> bool {
        self.diff.as_ref().is_some_and(|diff| {
            diff.deleted.get(path).is_some_and(|lines| {
                lines
                    .iter()
                    .any(|(line, text)| *line >= start && *line <= end && pattern.is_match(text))
            })
        })
    }

    pub(super) fn has_deleted_match(&self, path: &Path, pattern: &Regex) -> bool {
        self.diff.as_ref().is_some_and(|diff| {
            diff.deleted
                .get(path)
                .is_some_and(|lines| lines.iter().any(|(_, text)| pattern.is_match(text)))
        })
    }

    pub(super) fn previous_content(&self, path: &Path) -> Option<String> {
        let root = self.git_root.as_deref()?;
        let old_path = self
            .diff
            .as_ref()
            .and_then(|diff| diff.renames.get(path))
            .map_or(path, PathBuf::as_path);
        let relative = old_path.strip_prefix(root).ok()?;
        let revision = if self.staged {
            "HEAD"
        } else {
            self.baseline.as_deref()?
        };
        let output = Command::new("git")
            .args(["-C"])
            .arg(root)
            .args([
                "show",
                &format!("{revision}:{}", relative.to_string_lossy()),
            ])
            .output()
            .ok()?;
        output
            .status
            .success()
            .then(|| String::from_utf8(output.stdout).ok())
            .flatten()
    }

    pub(super) fn keep_unsuppressed(&self, content: &str, findings: Vec<Finding>) -> Vec<Finding> {
        let lines = content.lines().collect::<Vec<_>>();
        findings
            .into_iter()
            .filter(|finding| {
                let Some(previous) = finding
                    .line
                    .checked_sub(2)
                    .and_then(|index| lines.get(index))
                else {
                    return true;
                };
                let trimmed = previous.trim_start();
                let Some(rest) = trimmed.strip_prefix("//") else {
                    return true;
                };
                let expected = format!("vibeguard-disable-next-line {}", finding.rule);
                let directive = rest.trim_start();
                let Some(suffix) = directive.strip_prefix(&expected) else {
                    return true;
                };
                !(suffix.is_empty()
                    || suffix.starts_with(char::is_whitespace)
                    || suffix.starts_with("--"))
            })
            .collect()
    }
}

fn git_root(target: &Path) -> Option<PathBuf> {
    let output = Command::new("git")
        .args(["-C"])
        .arg(target)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()?;
    output.status.success().then(|| {
        PathBuf::from(String::from_utf8_lossy(&output.stdout).trim())
            .canonicalize()
            .unwrap_or_else(|_| PathBuf::from(String::from_utf8_lossy(&output.stdout).trim()))
    })
}

fn read_staged_files(path: &Path, target: &Path) -> Result<Vec<PathBuf>> {
    let cwd = env::current_dir()?;
    let mut files = Vec::new();
    for raw in fs::read_to_string(path)?.lines() {
        if raw.trim().is_empty() {
            continue;
        }
        let candidate = PathBuf::from(raw.trim());
        let candidate = if candidate.is_absolute() {
            candidate
        } else {
            cwd.join(candidate)
        };
        let normalized = candidate.canonicalize().unwrap_or(candidate);
        if normalized.starts_with(target) {
            files.push(normalized);
        }
    }
    files.sort();
    files.dedup();
    Ok(files)
}

fn tracked_files(root: &Path, target: &Path) -> Result<Vec<PathBuf>> {
    let output = Command::new("git")
        .args(["-C"])
        .arg(root)
        .args(["ls-files", "-z"])
        .output()?;
    if !output.status.success() {
        return Err("git ls-files failed".into());
    }
    let mut files = output
        .stdout
        .split(|byte| *byte == 0)
        .filter(|field| !field.is_empty())
        .map(|field| root.join(String::from_utf8_lossy(field).as_ref()))
        .filter(|path| path.starts_with(target) && path.is_file())
        .collect::<Vec<_>>();
    files.sort();
    Ok(files)
}

fn walked_files(target: &Path) -> Result<Vec<PathBuf>> {
    fn visit(dir: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let path = entry.path();
            let name = entry.file_name();
            let file_type = entry.file_type()?;
            if file_type.is_dir() {
                if matches!(
                    name.to_str(),
                    Some(".git" | "target" | "node_modules" | "vendor" | "dist" | "build")
                ) {
                    continue;
                }
                visit(&path, files)?;
            } else if file_type.is_file() {
                files.push(path);
            }
        }
        Ok(())
    }
    let mut files = Vec::new();
    visit(target, &mut files)?;
    files.sort();
    Ok(files)
}

fn build_diff_map(root: &Path, staged: bool, baseline: Option<&str>) -> Result<DiffMap> {
    let mut command = Command::new("git");
    command
        .args(["-C"])
        .arg(root)
        .args(["-c", "core.quotePath=false", "diff"]);
    if staged {
        command.arg("--cached");
    } else if let Some(commit) = baseline {
        command.arg(format!("{commit}..HEAD"));
    }
    let output = command.args(["-M", "-U0", "--no-color"]).output()?;
    if !output.status.success() {
        return Err("git diff failed while building guard baseline".into());
    }
    let mut map = parse_diff(root, &String::from_utf8_lossy(&output.stdout));
    map.renames = rename_map(root, staged, baseline)?;
    Ok(map)
}

fn parse_diff(root: &Path, text: &str) -> DiffMap {
    let hunk = Regex::new(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@").expect("valid hunk regex");
    let mut map = DiffMap::default();
    let mut path = None;
    let mut new_line = 0usize;
    for line in text.lines() {
        if let Some(value) = line.strip_prefix("+++ ") {
            path = value
                .strip_prefix("b/")
                .filter(|value| *value != "/dev/null")
                .map(|value| root.join(value));
            continue;
        }
        if let Some(captures) = hunk.captures(line) {
            new_line = captures[1].parse::<usize>().unwrap_or(1);
            continue;
        }
        let Some(current) = path.as_ref() else {
            continue;
        };
        if line.starts_with('+') && !line.starts_with("+++") {
            map.added
                .entry(current.clone())
                .or_default()
                .insert(new_line);
            new_line += 1;
        } else if line.starts_with('-') && !line.starts_with("---") {
            map.deleted.entry(current.clone()).or_default().push((
                new_line.max(1),
                line.strip_prefix('-').unwrap_or(line).to_string(),
            ));
        } else if !line.starts_with('\\') {
            new_line += 1;
        }
    }
    map
}

fn rename_map(
    root: &Path,
    staged: bool,
    baseline: Option<&str>,
) -> Result<BTreeMap<PathBuf, PathBuf>> {
    let mut command = Command::new("git");
    command.args(["-C"]).arg(root).arg("diff");
    if staged {
        command.arg("--cached");
    } else if let Some(commit) = baseline {
        command.arg(format!("{commit}..HEAD"));
    }
    let output = command.args(["-M", "--name-status", "-z"]).output()?;
    if !output.status.success() {
        return Err("git diff --name-status failed".into());
    }
    let fields = output.stdout.split(|byte| *byte == 0).collect::<Vec<_>>();
    let mut renames = BTreeMap::new();
    let mut index = 0;
    while index + 2 < fields.len() {
        let status = String::from_utf8_lossy(fields[index]);
        index += 1;
        let old = String::from_utf8_lossy(fields[index]);
        index += 1;
        if status.starts_with('R') {
            let new = String::from_utf8_lossy(fields[index]);
            index += 1;
            renames.insert(root.join(new.as_ref()), root.join(old.as_ref()));
        }
    }
    Ok(renames)
}

fn path_enforcement_class(language: &str, rule: &str, target: &Path, path: &Path) -> (bool, bool) {
    let relative = path.strip_prefix(target).unwrap_or(path);
    let normalized = relative
        .to_string_lossy()
        .replace('\\', "/")
        .to_ascii_lowercase();
    let basename = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match language {
        "rust" => (
            path.extension().and_then(|value| value.to_str()) == Some("rs"),
            is_rust_test_path(relative)
                || ["target/", ".git/", "node_modules/", ".harness/worktrees/"]
                    .iter()
                    .any(|part| {
                        normalized.starts_with(part) || normalized.contains(&format!("/{part}"))
                    }),
        ),
        "go" => (
            basename.ends_with(".go"),
            basename.ends_with("_test.go")
                || normalized.starts_with("vendor/")
                || normalized.contains("/vendor/"),
        ),
        "typescript" => (
            matches!(
                path.extension().and_then(|value| value.to_str()),
                Some("ts" | "tsx" | "js" | "jsx")
            ),
            is_typescript_test_path(relative)
                || (rule == "console-residual" && is_console_exempt_path(relative)),
        ),
        _ => (true, false),
    }
}

fn is_console_exempt_path(path: &Path) -> bool {
    let normalized = format!(
        "/{}",
        path.to_string_lossy().replace('\\', "/").trim_matches('/')
    )
    .to_ascii_lowercase();
    let basename = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    normalized.contains("logger")
        || normalized.contains("logging")
        || normalized.contains("log.config")
        || normalized.contains("/debug.")
        || normalized.contains("/debug/")
        || matches!(
            basename.as_str(),
            "cli.ts" | "cli.tsx" | "cli.js" | "cli.jsx"
        )
}

pub(super) fn is_rust_test_path(path: &Path) -> bool {
    let normalized = format!(
        "/{}/",
        path.to_string_lossy().replace('\\', "/").trim_matches('/')
    )
    .to_ascii_lowercase();
    let basename = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    [
        "/tests/",
        "/test/",
        "/__tests__/",
        "/spec/",
        "/fixtures/",
        "/mocks/",
        "/testdata/",
        "/examples/",
        "/benches/",
    ]
    .iter()
    .any(|part| normalized.contains(part))
        || normalized
            .split('/')
            .any(|segment| segment.starts_with("test_"))
        || basename.starts_with("test_")
        || basename.ends_with("_test.rs")
        || basename.ends_with("_tests.rs")
        || matches!(basename.as_str(), "tests.rs" | "test_helpers.rs")
}

pub(super) fn is_typescript_test_path(path: &Path) -> bool {
    let normalized = format!(
        "/{}/",
        path.to_string_lossy().replace('\\', "/").trim_matches('/')
    )
    .to_ascii_lowercase();
    let basename = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    basename.contains(".test.")
        || basename.contains(".spec.")
        || ["/tests/", "/test/", "/__tests__/", "/vendor/"]
            .iter()
            .any(|part| normalized.contains(part))
}
