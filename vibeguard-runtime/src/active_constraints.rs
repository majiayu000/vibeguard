//! Runtime U-32 active constraint budget counter for configured hooks.

use regex::Regex;
use serde_json::json;
use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};

use crate::hook_checks::common::glob_match;

mod source_paths;
type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;
const WARN_THRESHOLD: usize = 15;
const BLOCK_THRESHOLD: usize = 30;
const COMPACT_RULES_START: &str = "<!-- vibeguard-generated-compact-rules:start -->";
const COMPACT_RULES_END: &str = "<!-- vibeguard-generated-compact-rules:end -->";

#[derive(Default)]
struct ActiveConstraintOptions {
    root: PathBuf,
    home: PathBuf,
    codex_home: Option<PathBuf>,
    host: HostScope,
    task_paths: Vec<String>,
    skills: Vec<String>,
    json: bool,
    hook_fields: bool,
    warn_threshold: usize,
    block_threshold: usize,
}

#[derive(Clone, Copy, Default, Eq, PartialEq)]
enum HostScope {
    #[default]
    All,
    Claude,
    Codex,
}

impl HostScope {
    fn parse(value: &str) -> Result<Self> {
        match value {
            "all" => Ok(Self::All),
            "claude" => Ok(Self::Claude),
            "codex" => Ok(Self::Codex),
            _ => Err(format!("--host must be one of all, claude, or codex: {value}").into()),
        }
    }

    fn includes_claude(self) -> bool {
        matches!(self, Self::All | Self::Claude)
    }

    fn includes_codex(self) -> bool {
        matches!(self, Self::All | Self::Codex)
    }
}

#[derive(Clone)]
struct Constraint {
    key: String,
    label: String,
}

#[derive(Clone)]
struct SourceReport {
    path: PathBuf,
    kind: String,
    count: usize,
}

pub fn run(args: &[String]) -> Result {
    let options = parse_active_args(args)?;
    let sources = discover_sources(&options);
    let (reports, constraints) = count_constraints(&sources);
    let total = constraints.len();
    let status = status_for(total, options.warn_threshold, options.block_threshold);

    if options.hook_fields {
        println!(
            "{} {} {} {} {}",
            status,
            total,
            options.warn_threshold,
            options.block_threshold,
            summary(&reports)
        );
    } else if options.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "status": status,
                "total": total,
                "warn_threshold": options.warn_threshold,
                "block_threshold": options.block_threshold,
                "sources": reports.iter().map(|report| json!({
                    "path": report.path,
                    "kind": report.kind,
                    "count": report.count,
                })).collect::<Vec<_>>(),
                "constraints": constraints.iter().map(|constraint| json!({
                    "id": if is_rule_id(&constraint.label) { &constraint.label } else { "" },
                    "label": constraint.label,
                })).collect::<Vec<_>>(),
            }))?
        );
    } else {
        println!(
            "U-32 effective constraint budget: {total} (warn>{}, block>{})",
            options.warn_threshold, options.block_threshold
        );
        println!("Status: {}", status.to_ascii_uppercase());
    }
    Ok(())
}

fn parse_active_args(args: &[String]) -> Result<ActiveConstraintOptions> {
    let mut options = ActiveConstraintOptions {
        root: PathBuf::from("."),
        home: std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(".")),
        codex_home: std::env::var_os("CODEX_HOME").map(PathBuf::from),
        warn_threshold: WARN_THRESHOLD,
        block_threshold: BLOCK_THRESHOLD,
        ..ActiveConstraintOptions::default()
    };
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--root" => {
                index += 1;
                options.root = PathBuf::from(args.get(index).ok_or("--root requires a path")?);
            }
            "--home" => {
                index += 1;
                options.home = PathBuf::from(args.get(index).ok_or("--home requires a path")?);
            }
            "--codex-home" => {
                index += 1;
                options.codex_home = Some(PathBuf::from(
                    args.get(index).ok_or("--codex-home requires a path")?,
                ));
            }
            "--host" => {
                index += 1;
                options.host = HostScope::parse(args.get(index).ok_or("--host requires a value")?)?;
            }
            "--task-path" => {
                index += 1;
                options.task_paths.push(
                    args.get(index)
                        .ok_or("--task-path requires a path")?
                        .clone(),
                );
            }
            "--skill" => {
                index += 1;
                options
                    .skills
                    .push(args.get(index).ok_or("--skill requires a name")?.clone());
            }
            "--warn-threshold" => {
                index += 1;
                options.warn_threshold = args
                    .get(index)
                    .ok_or("--warn-threshold requires a number")?
                    .parse()?;
            }
            "--block-threshold" => {
                index += 1;
                options.block_threshold = args
                    .get(index)
                    .ok_or("--block-threshold requires a number")?
                    .parse()?;
            }
            "--json" => options.json = true,
            "--hook-fields" => options.hook_fields = true,
            _ => {}
        }
        index += 1;
    }
    Ok(options)
}

fn discover_sources(options: &ActiveConstraintOptions) -> BTreeMap<PathBuf, String> {
    let mut sources = BTreeMap::new();
    let codex_home = options
        .codex_home
        .clone()
        .unwrap_or_else(|| options.home.join(".codex"));

    let mut global_files = Vec::new();
    if options.host.includes_claude() {
        global_files.push(options.home.join(".claude/CLAUDE.md"));
        global_files.push(options.home.join(".claude/AGENTS.md"));
    }
    if options.host.includes_codex() {
        global_files.push(codex_home.join("AGENTS.md"));
    }
    for path in global_files {
        add_source(&mut sources, &path, "global", options);
    }

    let mut project_files = Vec::new();
    if options.host.includes_codex() {
        project_files.extend(source_paths::codex_project_instruction_files(
            &options.root,
            &options.task_paths,
        ));
    }
    if options.host.includes_claude() {
        project_files.push(options.root.join("AGENTS.md"));
        project_files.push(options.root.join("CLAUDE.md"));
        project_files.push(options.root.join(".claude/CLAUDE.md"));
    }
    for path in project_files {
        add_source(&mut sources, &path, "project", options);
    }

    let mut global_rule_roots = Vec::new();
    if options.host.includes_claude() {
        global_rule_roots.push(options.home.join(".claude/rules"));
    }
    for base in global_rule_roots {
        for path in markdown_files(&base) {
            add_source(&mut sources, &path, "global-rule", options);
        }
    }

    if options.host.includes_claude() {
        for path in markdown_files(&options.root.join(".claude/rules")) {
            add_source(&mut sources, &path, "path-rule", options);
        }
    }
    for skill in &options.skills {
        let mut skill_roots = vec![options.root.join("skills"), options.root.join("workflows")];
        if options.host.includes_claude() {
            skill_roots.push(options.home.join(".claude/skills"));
        }
        if options.host.includes_codex() {
            skill_roots.push(codex_home.join("skills"));
        }
        for base in skill_roots {
            add_source(
                &mut sources,
                &base.join(skill).join("SKILL.md"),
                "skill",
                options,
            );
        }
    }
    sources
}

fn add_source(
    sources: &mut BTreeMap<PathBuf, String>,
    path: &Path,
    kind: &str,
    options: &ActiveConstraintOptions,
) {
    if !path.is_file() {
        return;
    }
    let text = read_text(path);
    if !matches_task_path(&text, &options.task_paths) {
        return;
    }
    let resolved = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    sources.entry(resolved).or_insert_with(|| kind.to_string());
}

fn markdown_files(base: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    visit_markdown(base, &mut out);
    out
}

fn visit_markdown(path: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(path) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            visit_markdown(&path, out);
        } else if path.extension().and_then(|ext| ext.to_str()) == Some("md") {
            out.push(path);
        }
    }
}

fn read_text(path: &Path) -> String {
    std::fs::read(path)
        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
        .unwrap_or_default()
}

fn matches_task_path(text: &str, task_paths: &[String]) -> bool {
    let Some(frontmatter) = text
        .strip_prefix("---\n")
        .and_then(|rest| rest.split_once("\n---\n"))
    else {
        return true;
    };
    let paths = frontmatter
        .0
        .lines()
        .find_map(|line| line.strip_prefix("paths:").map(str::trim))
        .unwrap_or("");
    if paths.is_empty() {
        return true;
    }
    if task_paths.is_empty() {
        return false;
    }
    paths.split(',').map(str::trim).any(|pattern| {
        task_paths
            .iter()
            .any(|path| glob_match(pattern, path) || glob_match(pattern, &format!("./{path}")))
    })
}

fn count_constraints(sources: &BTreeMap<PathBuf, String>) -> (Vec<SourceReport>, Vec<Constraint>) {
    let rule_re = match Regex::new(r"^##\s+((?:U|W|SEC|RS|PY|TS|GO|TASTE)-\d+):") {
        Ok(regex) => regex,
        Err(err) => panic!("invalid active constraint rule regex: {err}"),
    };
    let bullet_re = match Regex::new(r"^\s*(?:[-*+]|\d+[.)])\s+(.+)") {
        Ok(regex) => regex,
        Err(err) => panic!("invalid active constraint bullet regex: {err}"),
    };
    let table_rule_re = match Regex::new(r"^(?:U|W|SEC|RS|PY|TS|GO|TASTE)-\d+$") {
        Ok(regex) => regex,
        Err(err) => panic!("invalid active constraint table rule regex: {err}"),
    };
    let normative_re = match Regex::new(
        r"(?i)\b(must|must not|should|should not|never|always|require|requires|required|avoid|do not|don't|prohibit|forbid|block|verify)\b|必须|禁止|不要|不得|需要|要求|阻断|验证",
    ) {
        Ok(regex) => regex,
        Err(err) => panic!("invalid active constraint normative regex: {err}"),
    };
    let mut parsed_sources = Vec::new();
    for (path, kind) in sources {
        let text = read_text(path);
        let mut source_constraints = Vec::new();
        let mut in_fence = false;
        let mut in_core_contract = false;
        let mut in_compact_rules = false;
        for line in text.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with("```") {
                in_fence = !in_fence;
                continue;
            }
            if in_fence {
                continue;
            }
            if trimmed == COMPACT_RULES_START {
                in_compact_rules = true;
                continue;
            }
            if trimmed == COMPACT_RULES_END {
                in_compact_rules = false;
                continue;
            }
            if trimmed.starts_with("## ") {
                in_core_contract = trimmed == "## Core contract";
            }
            if trimmed.starts_with('|') {
                let cells = trimmed
                    .trim_matches('|')
                    .split('|')
                    .map(str::trim)
                    .collect::<Vec<_>>();
                let first_cell = cells.first().copied().unwrap_or("");
                if in_compact_rules && table_rule_re.is_match(first_cell) {
                    source_constraints.push(Constraint {
                        key: rule_constraint_key(first_cell),
                        label: first_cell.to_string(),
                    });
                } else if in_core_contract
                    && cells.len() >= 2
                    && first_cell != "Area"
                    && !first_cell.is_empty()
                    && !first_cell.chars().all(|ch| matches!(ch, '-' | ':'))
                {
                    let normalized_area = first_cell
                        .split_whitespace()
                        .collect::<Vec<_>>()
                        .join(" ")
                        .to_ascii_lowercase();
                    let normalized_default = cells[1]
                        .split_whitespace()
                        .collect::<Vec<_>>()
                        .join(" ")
                        .to_ascii_lowercase();
                    source_constraints.push(Constraint {
                        key: core_constraint_key(&normalized_area, &normalized_default),
                        label: format!("Core contract: {first_cell}"),
                    });
                }
                continue;
            }
            if let Some(caps) = rule_re.captures(line) {
                let rule_id = caps[1].to_string();
                source_constraints.push(Constraint {
                    key: rule_constraint_key(&rule_id),
                    label: rule_id,
                });
            } else if let Some(caps) = bullet_re.captures(line)
                && normative_re.is_match(&caps[1])
            {
                let label = caps[1].trim().to_string();
                let normalized = label
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ")
                    .to_ascii_lowercase();
                source_constraints.push(Constraint {
                    key: format!("text:{normalized}"),
                    label,
                });
            }
        }
        parsed_sources.push((path.clone(), kind.clone(), source_constraints));
    }

    let mut seen = HashSet::new();
    let mut source_counts = BTreeMap::<PathBuf, usize>::new();
    let mut constraints = Vec::new();
    // Prefer canonical rule IDs to equivalent shared-core rows so JSON and GC
    // reports retain a useful ID while the semantic requirement counts once.
    for rule_pass in [true, false] {
        for (path, _kind, candidates) in &parsed_sources {
            for candidate in candidates {
                if is_rule_id(&candidate.label) != rule_pass || !seen.insert(candidate.key.clone())
                {
                    continue;
                }
                *source_counts.entry(path.clone()).or_default() += 1;
                constraints.push(candidate.clone());
            }
        }
    }

    let reports = parsed_sources
        .into_iter()
        .filter_map(|(path, kind, _candidates)| {
            let count = source_counts.get(&path).copied().unwrap_or_default();
            (count > 0).then_some(SourceReport { path, kind, count })
        })
        .collect();
    (reports, constraints)
}

fn is_rule_id(value: &str) -> bool {
    let Some((prefix, number)) = value.split_once('-') else {
        return false;
    };
    matches!(
        prefix,
        "U" | "W" | "SEC" | "RS" | "PY" | "TS" | "GO" | "TASTE"
    ) && !number.is_empty()
        && number.chars().all(|ch| ch.is_ascii_digit())
}

fn rule_constraint_key(rule_id: &str) -> String {
    format!("rule:{rule_id}")
}
fn core_constraint_key(area: &str, requirement: &str) -> String {
    match (area, requirement) {
        (
            "errors",
            "user-visible missing data, malformed input, or wrong output must fail clearly.",
        ) => rule_constraint_key("U-29"),
        ("scope", "make the smallest requested change; do not add adjacent improvements.") => {
            rule_constraint_key("U-04")
        }
        ("verification", "run a fresh, focused project command before claiming completion.") => {
            rule_constraint_key("W-03")
        }
        _ => format!("core:{area}:{requirement}"),
    }
}

fn status_for(total: usize, warn_threshold: usize, block_threshold: usize) -> &'static str {
    if total > block_threshold {
        "block"
    } else if total > warn_threshold {
        "warn"
    } else {
        "ok"
    }
}

fn summary(reports: &[SourceReport]) -> String {
    let mut reports = reports.to_vec();
    reports.sort_by(|a, b| b.count.cmp(&a.count).then_with(|| a.path.cmp(&b.path)));
    reports
        .iter()
        .take(3)
        .map(|report| format!("{} {} {}", report.count, report.kind, report.path.display()))
        .collect::<Vec<_>>()
        .join("; ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(name: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "vibeguard-active-constraints-{name}-{}-{unique}",
            std::process::id()
        ));
        if let Err(err) = fs::create_dir_all(&dir) {
            panic!("temp dir should be created: {err}");
        }
        dir
    }

    #[test]
    fn discover_sources_filters_global_files_by_host() {
        let dir = temp_dir("host");
        let root = dir.join("repo");
        let home = dir.join("home");
        fs::create_dir_all(home.join(".claude"))
            .unwrap_or_else(|err| panic!("Claude home should be created: {err}"));
        fs::create_dir_all(home.join(".codex"))
            .unwrap_or_else(|err| panic!("Codex home should be created: {err}"));
        fs::create_dir_all(&root)
            .unwrap_or_else(|err| panic!("repo root should be created: {err}"));
        fs::write(
            home.join(".claude/CLAUDE.md"),
            "- Must keep Claude global guidance\n",
        )
        .unwrap_or_else(|err| panic!("Claude global guidance should be written: {err}"));
        fs::write(
            home.join(".codex/AGENTS.md"),
            "- Must not count Codex global guidance\n",
        )
        .unwrap_or_else(|err| panic!("Codex global guidance should be written: {err}"));

        let options = ActiveConstraintOptions {
            root,
            home,
            host: HostScope::Claude,
            ..ActiveConstraintOptions::default()
        };
        let sources = discover_sources(&options);
        let (_reports, constraints) = count_constraints(&sources);
        let labels = constraints
            .iter()
            .map(|constraint| constraint.label.as_str())
            .collect::<Vec<_>>();

        assert_eq!(constraints.len(), 1);
        assert!(labels.contains(&"Must keep Claude global guidance"));
        assert!(!labels.contains(&"Must not count Codex global guidance"));

        fs::remove_dir_all(dir).unwrap_or_else(|err| panic!("temp dir should be removed: {err}"));
    }

    #[test]
    fn frontmatter_paths_gate_path_scoped_rules() {
        let text = "---\npaths: src/*.rs, docs/**\n---\n- Must verify changes\n";

        assert!(!matches_task_path(text, &[]));
        assert!(matches_task_path(text, &["src/main.rs".to_string()]));
        assert!(matches_task_path(text, &["docs/spec.md".to_string()]));
        assert!(!matches_task_path(text, &["tests/main.rs".to_string()]));
    }

    #[test]
    fn count_constraints_dedupes_rules_and_ignores_unrelated_tables_and_fences() {
        let dir = temp_dir("count");
        let first = dir.join("first.md");
        let second = dir.join("second.md");
        fs::write(
            &first,
            "## U-16: File size\n- Must verify build\n| - Must not count table |\n```\n- Must not count fenced\n```\n",
        )
        .unwrap_or_else(|err| panic!("first fixture should be written: {err}"));
        fs::write(
            &second,
            "## U-16: Duplicate rule\n- Must verify build\n- Never swallow errors\n",
        )
        .unwrap_or_else(|err| panic!("second fixture should be written: {err}"));

        let mut sources = BTreeMap::new();
        sources.insert(first, "project".to_string());
        sources.insert(second, "project".to_string());
        let (reports, constraints) = count_constraints(&sources);
        let labels = constraints
            .iter()
            .map(|constraint| constraint.label.as_str())
            .collect::<Vec<_>>();

        assert_eq!(constraints.len(), 3);
        assert!(labels.contains(&"U-16"));
        assert!(labels.contains(&"Must verify build"));
        assert!(labels.contains(&"Never swallow errors"));
        assert_eq!(reports.iter().map(|report| report.count).sum::<usize>(), 3);

        fs::remove_dir_all(dir).unwrap_or_else(|err| panic!("temp dir should be removed: {err}"));
    }

    #[test]
    fn codex_sources_use_configured_home_and_exclude_claude_project_files() {
        let dir = temp_dir("codex-home");
        let root = dir.join("repo");
        let home = dir.join("home");
        let codex_home = dir.join("custom-codex");
        fs::create_dir_all(home.join(".codex"))
            .unwrap_or_else(|err| panic!("fallback Codex home should be created: {err}"));
        fs::create_dir_all(&codex_home)
            .unwrap_or_else(|err| panic!("custom Codex home should be created: {err}"));
        fs::create_dir_all(codex_home.join("rules"))
            .unwrap_or_else(|err| panic!("Codex rule decoy directory should be created: {err}"));
        fs::create_dir_all(root.join(".claude/rules"))
            .unwrap_or_else(|err| panic!("Claude project rules should be created: {err}"));
        fs::write(
            home.join(".codex/AGENTS.md"),
            "- Must not count fallback Codex guidance\n",
        )
        .unwrap_or_else(|err| panic!("fallback Codex guidance should be written: {err}"));
        fs::write(
            codex_home.join("AGENTS.md"),
            "- Must count configured Codex guidance\n",
        )
        .unwrap_or_else(|err| panic!("configured Codex guidance should be written: {err}"));
        fs::write(
            codex_home.join("rules/decoy.md"),
            "- Must not count unsupported Codex native rules\n",
        )
        .unwrap_or_else(|err| panic!("Codex rule decoy should be written: {err}"));
        fs::write(root.join("AGENTS.md"), "- Must count project AGENTS\n")
            .unwrap_or_else(|err| panic!("project AGENTS should be written: {err}"));
        fs::write(
            root.join("CLAUDE.md"),
            "- Must not count project Claude guidance\n",
        )
        .unwrap_or_else(|err| panic!("project Claude guidance should be written: {err}"));
        fs::write(
            root.join(".claude/rules/claude.md"),
            "- Must not count project Claude rules\n",
        )
        .unwrap_or_else(|err| panic!("project Claude rules should be written: {err}"));

        let options = ActiveConstraintOptions {
            root,
            home,
            codex_home: Some(codex_home),
            host: HostScope::Codex,
            ..ActiveConstraintOptions::default()
        };
        let sources = discover_sources(&options);
        let (_reports, constraints) = count_constraints(&sources);
        let labels = constraints
            .iter()
            .map(|constraint| constraint.label.as_str())
            .collect::<Vec<_>>();

        assert_eq!(constraints.len(), 2);
        assert!(labels.contains(&"Must count configured Codex guidance"));
        assert!(labels.contains(&"Must count project AGENTS"));
        assert!(!labels.iter().any(|label| label.contains("Claude")));
        assert!(!labels.iter().any(|label| label.contains("fallback")));
        assert!(!labels.iter().any(|label| label.contains("native rules")));

        fs::remove_dir_all(dir).unwrap_or_else(|err| panic!("temp dir should be removed: {err}"));
    }

    #[test]
    fn count_constraints_reads_compact_rule_and_core_contract_tables() {
        let dir = temp_dir("managed-tables");
        let source = dir.join("AGENTS.md");
        fs::write(
            &source,
            "## Core contract\n\n| Area | Default |\n|---|---|\n| Scope | Keep changes focused. |\n| Verification | Run focused tests. |\n\n## Key detailed rules\n\n<!-- vibeguard-generated-compact-rules:start -->\n| ID | Severity | Rule |\n|---|---|---|\n| U-10 | Strict | Verify. |\n| W-11 | Strict | Verify. |\n<!-- vibeguard-generated-compact-rules:end -->\n",
        )
        .unwrap_or_else(|err| panic!("table fixture should be written: {err}"));

        let mut sources = BTreeMap::new();
        sources.insert(source, "global".to_string());
        let (_reports, constraints) = count_constraints(&sources);
        let labels = constraints
            .iter()
            .map(|constraint| constraint.label.as_str())
            .collect::<Vec<_>>();

        assert_eq!(constraints.len(), 4);
        assert!(labels.contains(&"Core contract: Scope"));
        assert!(labels.contains(&"Core contract: Verification"));
        assert!(labels.contains(&"U-10"));
        assert!(labels.contains(&"W-11"));

        fs::remove_dir_all(dir).unwrap_or_else(|err| panic!("temp dir should be removed: {err}"));
    }

    #[test]
    fn count_constraints_ignores_rule_inventory_outside_generated_marker() {
        let dir = temp_dir("ordinary-rule-inventory");
        let source = dir.join("AGENTS.md");
        fs::write(
            &source,
            "## Rule inventory\n\n| ID | State |\n|---|---|\n| U-01 | disabled |\n",
        )
        .unwrap_or_else(|err| panic!("inventory fixture should be written: {err}"));

        let mut sources = BTreeMap::new();
        sources.insert(source, "global".to_string());
        let (reports, constraints) = count_constraints(&sources);

        assert!(reports.is_empty());
        assert!(constraints.is_empty());

        fs::remove_dir_all(dir).unwrap_or_else(|err| panic!("temp dir should be removed: {err}"));
    }

    #[test]
    fn shared_core_rows_keep_distinct_rule_ids() {
        let dir = temp_dir("shared-core-equivalents");
        let source = dir.join("AGENTS.md");
        fs::write(
            &source,
            "## Core contract\n\n| Area | Default |\n|---|---|\n| Errors | User-visible missing data, malformed input, or wrong output must fail clearly. |\n| Scope | Make the smallest requested change; do not add adjacent improvements. |\n| Safety | Never expose secrets, add hidden AI attribution, force-push, or weaken tests. |\n| Preservation | Preserve unmanaged content in high-context files, settings, and hooks. |\n| Verification | Run a fresh, focused project command before claiming completion. |\n\n## Key detailed rules\n\n<!-- vibeguard-generated-compact-rules:start -->\n| ID | Severity | Rule |\n|---|---|---|\n| SEC-02 | Strict | Secrets. |\n| SEC-13 | Strict | Preservation. |\n| U-04 | Strict | Scope. |\n| U-08 | Strict | Verification. |\n| U-17 | Strict | Errors. |\n| U-29 | Strict | Errors. |\n| W-03 | Strict | Verification. |\n| W-12 | Strict | Safety. |\n| W-16 | Strict | Verification. |\n<!-- vibeguard-generated-compact-rules:end -->\n",
        )
        .unwrap_or_else(|err| panic!("equivalence fixture should be written: {err}"));

        let mut sources = BTreeMap::new();
        sources.insert(source, "global".to_string());
        let (_reports, constraints) = count_constraints(&sources);

        assert_eq!(constraints.len(), 11);
        assert_eq!(
            constraints
                .iter()
                .map(|constraint| constraint.label.as_str())
                .collect::<Vec<_>>(),
            [
                "SEC-02",
                "SEC-13",
                "U-04",
                "U-08",
                "U-17",
                "U-29",
                "W-03",
                "W-12",
                "W-16",
                "Core contract: Safety",
                "Core contract: Preservation",
            ]
        );

        fs::remove_dir_all(dir).unwrap_or_else(|err| panic!("temp dir should be removed: {err}"));
    }

    #[test]
    fn core_contract_rows_dedupe_by_area_and_constraint_text() {
        let dir = temp_dir("core-row-dedupe");
        let first = dir.join("global.md");
        let second = dir.join("project.md");
        fs::write(
            &first,
            "## Core contract\n\n| Area | Default |\n|---|---|\n| Scope | Keep changes focused. |\n",
        )
        .unwrap_or_else(|err| panic!("global core fixture should be written: {err}"));
        fs::write(
            &second,
            "## Core contract\n\n| Area | Default |\n|---|---|\n| Scope | Do not edit generated files. |\n",
        )
        .unwrap_or_else(|err| panic!("project core fixture should be written: {err}"));

        let mut sources = BTreeMap::new();
        sources.insert(first, "global".to_string());
        sources.insert(second, "project".to_string());
        let (reports, constraints) = count_constraints(&sources);

        assert_eq!(constraints.len(), 2);
        assert_eq!(reports.iter().map(|report| report.count).sum::<usize>(), 2);

        fs::remove_dir_all(dir).unwrap_or_else(|err| panic!("temp dir should be removed: {err}"));
    }

    #[test]
    fn status_thresholds_are_strictly_greater_than_limits() {
        assert_eq!(status_for(15, 15, 30), "ok");
        assert_eq!(status_for(16, 15, 30), "warn");
        assert_eq!(status_for(31, 15, 30), "block");
    }
}
