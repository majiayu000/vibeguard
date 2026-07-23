use crate::HandlerResult;
use crate::hook_checks_common::{count_lines, is_source_path, is_test_path};
use crate::runtime_config::runtime_config_int_value;
use crate::u16_config::u16_limit_from_claude_text;
use std::path::PathBuf;
use std::process::{self, Command};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum U16BaselineDecision {
    Allow,
    LegacyDebt,
    Block(U16BlockReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum U16BlockReason {
    NewOversized,
    CrossesLimit,
    LegacyGrowth,
}

impl U16BlockReason {
    fn code(self) -> &'static str {
        match self {
            Self::NewOversized => "new_oversized",
            Self::CrossesLimit => "crosses_limit",
            Self::LegacyGrowth => "legacy_growth",
        }
    }
}

pub(crate) fn evaluate_u16_baseline(
    existed_before: bool,
    old_lines: usize,
    new_lines: usize,
    limit: usize,
) -> U16BaselineDecision {
    if new_lines <= limit {
        return U16BaselineDecision::Allow;
    }
    if !existed_before {
        return U16BaselineDecision::Block(U16BlockReason::NewOversized);
    }
    if old_lines <= limit {
        return U16BaselineDecision::Block(U16BlockReason::CrossesLimit);
    }
    if new_lines > old_lines {
        return U16BaselineDecision::Block(U16BlockReason::LegacyGrowth);
    }
    U16BaselineDecision::LegacyDebt
}

pub(crate) fn legacy_debt_context(
    file_path: &str,
    old_lines: usize,
    new_lines: usize,
    limit: usize,
) -> String {
    format!(
        "VIBEGUARD [U-16] [advisory] [U16_LEGACY_DEBT] OBSERVATION: legacy oversized file {} remains over the {limit}-line hard limit but did not grow ({old_lines} -> {new_lines} lines)\nSCOPE: keep the current change localized; continue reducing this file in focused follow-up work\nACTION: NONE - advisory only, continue without acknowledgement",
        u16_display_name(file_path)
    )
}

pub(crate) fn u16_advisory_limit(base_limit: usize, hard_limit: usize, warn_limit: usize) -> usize {
    if hard_limit > base_limit {
        hard_limit
    } else {
        warn_limit.min(hard_limit)
    }
}

pub(crate) fn edit_advisory_context(
    file_path: &str,
    line_count: usize,
    warn_limit: usize,
    hard_limit: usize,
) -> String {
    format!(
        "VIBEGUARD [U-16] [advisory] [this-file] OBSERVATION: this edit would leave {} with {line_count} lines exceeds the {warn_limit}-line typical range but stays under the {hard_limit}-line hard limit\nSCOPE: keep the current change localized; plan a split if this file keeps growing\nACTION: NONE - advisory only, continue without acknowledgement",
        u16_display_name(file_path)
    )
}

pub(crate) fn write_advisory_context(
    file_path: &str,
    line_count: usize,
    warn_limit: usize,
    limit: usize,
    include_search: bool,
) -> String {
    let mut context = format!(
        "VIBEGUARD [U-16] [advisory] [this-file] OBSERVATION: writing {} with {line_count} lines exceeds the {warn_limit}-line typical range but stays under the {limit}-line hard limit\nSCOPE: keep the current change localized; plan a split if this file keeps growing\nACTION: NONE - advisory only, continue without acknowledgement",
        u16_display_name(file_path)
    );
    if include_search {
        context.push_str("\n---\n");
        context.push_str(L1_ADVISORY_CONTEXT);
    }
    context
}

pub(crate) fn run_cli(args: &[String]) -> HandlerResult {
    let config = U16CliConfig::from_args(args)?;
    let base_limit = config
        .base_limit
        .unwrap_or_else(|| runtime_config_int_value("VG_U16_LIMIT", "u16.limit", "800") as usize);
    let limit_snapshot = U16LimitSnapshot::load(&config.mode)?;
    let entries = diff_entries(&config.mode)?;
    let mut blocks = Vec::new();
    let mut legacy = Vec::new();

    for entry in entries {
        if !is_u16_enforced_path(&entry.new_path) {
            continue;
        }
        let old_content = match entry.old_path_for_baseline() {
            Some(old_path) if is_u16_enforced_path(&old_path) => {
                Some(read_blob(&config.mode, OldOrNew::Old, &old_path)?)
            }
            _ => None,
        };
        let new_content = read_blob(&config.mode, OldOrNew::New, &entry.new_path)?;
        let old_lines = old_content
            .as_ref()
            .map(|content| count_lines(content))
            .unwrap_or(0);
        let new_lines = count_lines(&new_content);
        let limit = limit_snapshot.limit_for(&entry.new_path, base_limit);

        match evaluate_u16_baseline(old_content.is_some(), old_lines, new_lines, limit) {
            U16BaselineDecision::Allow => {}
            U16BaselineDecision::LegacyDebt => legacy.push(U16Finding {
                path: entry.new_path,
                old_lines,
                new_lines,
                limit,
                reason: "legacy_debt",
            }),
            U16BaselineDecision::Block(reason) => blocks.push(U16Finding {
                path: entry.new_path,
                old_lines,
                new_lines,
                limit,
                reason: reason.code(),
            }),
        }
    }

    if !blocks.is_empty() {
        println!("U16_BASELINE_BLOCK");
        for finding in &blocks {
            println!(
                "{}\t{}\t{}\t{}\t{}",
                finding.path, finding.old_lines, finding.new_lines, finding.limit, finding.reason
            );
        }
        process::exit(1);
    }

    if !legacy.is_empty() {
        println!("U16_LEGACY_DEBT");
        for finding in &legacy {
            println!(
                "{}\t{}\t{}\t{}",
                finding.path, finding.old_lines, finding.new_lines, finding.limit
            );
        }
    } else {
        println!("U16_BASELINE_OK");
    }
    Ok(())
}

#[derive(Debug)]
struct U16Finding {
    path: String,
    old_lines: usize,
    new_lines: usize,
    limit: usize,
    reason: &'static str,
}

#[derive(Debug)]
struct U16CliConfig {
    mode: U16GitMode,
    base_limit: Option<usize>,
}

struct U16LimitSnapshot {
    project_root: PathBuf,
    claude_text: Option<String>,
}

impl U16LimitSnapshot {
    fn load(mode: &U16GitMode) -> Result<Self, String> {
        let project_root = git_stdout(&["rev-parse".to_string(), "--show-toplevel".to_string()])?;
        let project_root = project_root.trim();
        if project_root.is_empty() {
            return Err("git rev-parse --show-toplevel returned an empty path".to_string());
        }

        let claude_text = if new_blob_exists(mode, "CLAUDE.md")? {
            Some(read_blob(mode, OldOrNew::New, "CLAUDE.md")?)
        } else {
            None
        };

        Ok(Self {
            project_root: PathBuf::from(project_root),
            claude_text,
        })
    }

    fn limit_for(&self, file_path: &str, base_limit: usize) -> usize {
        match &self.claude_text {
            Some(text) => {
                u16_limit_from_claude_text(text, file_path, &self.project_root, base_limit)
            }
            None => base_limit,
        }
    }
}

impl U16CliConfig {
    fn from_args(args: &[String]) -> Result<Self, String> {
        let mut mode = None;
        let mut head = "HEAD".to_string();
        let mut base_limit = None;
        let mut idx = 0;
        while idx < args.len() {
            match args[idx].as_str() {
                "--staged" => {
                    if mode.replace(U16GitMode::Staged).is_some() {
                        return Err("u16-baseline-check accepts one source mode".to_string());
                    }
                    idx += 1;
                }
                "--base" => {
                    let base = args
                        .get(idx + 1)
                        .ok_or_else(|| "--base requires a ref".to_string())?
                        .to_string();
                    mode = Some(U16GitMode::Base {
                        base,
                        head: head.clone(),
                    });
                    idx += 2;
                }
                "--head" => {
                    head = args
                        .get(idx + 1)
                        .ok_or_else(|| "--head requires a ref".to_string())?
                        .to_string();
                    if let Some(U16GitMode::Base { base, .. }) = mode.take() {
                        mode = Some(U16GitMode::Base {
                            base,
                            head: head.clone(),
                        });
                    }
                    idx += 2;
                }
                "--base-limit" => {
                    let value = args
                        .get(idx + 1)
                        .ok_or_else(|| "--base-limit requires an integer".to_string())?
                        .parse::<usize>()
                        .map_err(|_| "--base-limit requires an integer".to_string())?;
                    base_limit = Some(value);
                    idx += 2;
                }
                _ => {
                    return Err(
                        "Usage: vibeguard-runtime u16-baseline-check (--staged|--base <ref> [--head <ref>]) [--base-limit <n>]"
                            .to_string(),
                    );
                }
            }
        }
        let mode = mode.ok_or_else(|| {
            "Usage: vibeguard-runtime u16-baseline-check (--staged|--base <ref> [--head <ref>]) [--base-limit <n>]"
                .to_string()
        })?;
        Ok(Self { mode, base_limit })
    }
}

#[derive(Debug)]
enum U16GitMode {
    Staged,
    Base { base: String, head: String },
}

enum OldOrNew {
    Old,
    New,
}

#[derive(Debug)]
struct DiffEntry {
    status: String,
    old_path: Option<String>,
    new_path: String,
}

impl DiffEntry {
    fn old_path_for_baseline(&self) -> Option<String> {
        if self.status.starts_with('A') {
            None
        } else if self.status.starts_with('R') {
            self.old_path.clone()
        } else {
            Some(self.new_path.clone())
        }
    }
}

fn diff_entries(mode: &U16GitMode) -> Result<Vec<DiffEntry>, String> {
    let mut args = vec![
        "diff".to_string(),
        "--name-status".to_string(),
        "-z".to_string(),
        "-M".to_string(),
        "--diff-filter=AMR".to_string(),
    ];
    match mode {
        U16GitMode::Staged => args.push("--cached".to_string()),
        U16GitMode::Base { base, head } => {
            let merge_base =
                git_stdout(&["merge-base".to_string(), base.to_string(), head.to_string()])?;
            args.push(merge_base.trim().to_string());
            args.push(head.to_string());
        }
    }
    parse_name_status(&git_bytes(&args)?)
}

fn parse_name_status(bytes: &[u8]) -> Result<Vec<DiffEntry>, String> {
    let fields = bytes
        .split(|byte| *byte == 0)
        .filter(|field| !field.is_empty())
        .collect::<Vec<_>>();
    let mut entries = Vec::new();
    let mut idx = 0;
    while idx < fields.len() {
        let status = String::from_utf8_lossy(fields[idx]).into_owned();
        idx += 1;
        if status.starts_with('R') {
            let old_path = fields
                .get(idx)
                .ok_or_else(|| "git diff rename entry missing old path".to_string())?;
            let new_path = fields
                .get(idx + 1)
                .ok_or_else(|| "git diff rename entry missing new path".to_string())?;
            idx += 2;
            entries.push(DiffEntry {
                status,
                old_path: Some(String::from_utf8_lossy(old_path).into_owned()),
                new_path: String::from_utf8_lossy(new_path).into_owned(),
            });
        } else {
            let new_path = fields
                .get(idx)
                .ok_or_else(|| "git diff entry missing path".to_string())?;
            idx += 1;
            entries.push(DiffEntry {
                status,
                old_path: None,
                new_path: String::from_utf8_lossy(new_path).into_owned(),
            });
        }
    }
    Ok(entries)
}

fn read_blob(mode: &U16GitMode, which: OldOrNew, path: &str) -> Result<String, String> {
    let spec = match (mode, which) {
        (U16GitMode::Staged, OldOrNew::Old) => format!("HEAD:{path}"),
        (U16GitMode::Staged, OldOrNew::New) => format!(":{path}"),
        (U16GitMode::Base { base, head }, OldOrNew::Old) => {
            let merge_base =
                git_stdout(&["merge-base".to_string(), base.to_string(), head.to_string()])?;
            format!("{}:{path}", merge_base.trim())
        }
        (U16GitMode::Base { head, .. }, OldOrNew::New) => format!("{head}:{path}"),
    };
    git_stdout(&["show".to_string(), spec])
}

fn new_blob_exists(mode: &U16GitMode, path: &str) -> Result<bool, String> {
    let args = match mode {
        U16GitMode::Staged => vec![
            "ls-files".to_string(),
            "--cached".to_string(),
            "-z".to_string(),
            "--".to_string(),
            path.to_string(),
        ],
        U16GitMode::Base { head, .. } => vec![
            "ls-tree".to_string(),
            "--name-only".to_string(),
            "-z".to_string(),
            head.to_string(),
            "--".to_string(),
            path.to_string(),
        ],
    };
    Ok(!git_bytes(&args)?.is_empty())
}

fn git_bytes(args: &[String]) -> Result<Vec<u8>, String> {
    let output = Command::new("git")
        .args(args)
        .output()
        .map_err(|err| format!("git {} failed to start: {err}", args.join(" ")))?;
    if !output.status.success() {
        return Err(format!(
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(output.stdout)
}

fn git_stdout(args: &[String]) -> Result<String, String> {
    Ok(String::from_utf8_lossy(&git_bytes(args)?).into_owned())
}

fn is_u16_enforced_path(path: &str) -> bool {
    is_source_path(path) && !is_test_path(path)
}

pub(crate) fn u16_display_name(path: &str) -> &str {
    std::path::Path::new(path)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(path)
}

pub(crate) const L1_ADVISORY_CONTEXT: &str = "VIBEGUARD [L1] [advisory] [this-edit] OBSERVATION: new source file detected - search for similar implementation before adding duplicates\nSCOPE: if not yet checked, consider Grep for functions/classes/structs and Glob for same-named files\nACTION: NONE - advisory only, continue without acknowledgement";

#[cfg(test)]
#[path = "u16_baseline_tests.rs"]
mod tests;
