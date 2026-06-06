//! Runtime U-32 active constraint budget counter for configured hooks.

use regex::Regex;
use serde_json::json;
use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};

use crate::hook_checks_common::glob_match;

type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;

const WARN_THRESHOLD: usize = 15;
const BLOCK_THRESHOLD: usize = 30;

#[derive(Default)]
struct ActiveConstraintOptions {
    root: PathBuf,
    home: PathBuf,
    task_paths: Vec<String>,
    skills: Vec<String>,
    json: bool,
    hook_fields: bool,
    warn_threshold: usize,
    block_threshold: usize,
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
                    "id": if constraint.key.starts_with("rule:") { &constraint.label } else { "" },
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
    for (path, kind) in [
        (options.home.join(".claude/CLAUDE.md"), "global"),
        (options.home.join(".claude/AGENTS.md"), "global"),
        (options.home.join(".codex/AGENTS.md"), "global"),
        (options.root.join("AGENTS.md"), "project"),
        (options.root.join("CLAUDE.md"), "project"),
        (options.root.join(".claude/CLAUDE.md"), "project"),
    ] {
        add_source(&mut sources, &path, kind, options);
    }
    for base in [
        options.home.join(".claude/rules"),
        options.home.join(".codex/rules"),
        options.root.join(".claude/rules"),
    ] {
        for path in markdown_files(&base) {
            add_source(&mut sources, &path, "path-rule", options);
        }
    }
    for skill in &options.skills {
        for base in [
            options.root.join("skills"),
            options.root.join("workflows"),
            options.home.join(".claude/skills"),
            options.home.join(".codex/skills"),
        ] {
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
    let normative_re = match Regex::new(
        r"(?i)\b(must|must not|should|should not|never|always|require|requires|required|avoid|do not|don't|prohibit|forbid|block|verify)\b|必须|禁止|不要|不得|需要|要求|阻断|验证",
    ) {
        Ok(regex) => regex,
        Err(err) => panic!("invalid active constraint normative regex: {err}"),
    };
    let mut seen = HashSet::new();
    let mut reports = Vec::new();
    let mut constraints = Vec::new();
    for (path, kind) in sources {
        let text = read_text(path);
        let mut source_constraints = Vec::new();
        let mut in_fence = false;
        for line in text.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with("```") {
                in_fence = !in_fence;
                continue;
            }
            if in_fence || trimmed.starts_with('|') {
                continue;
            }
            if let Some(caps) = rule_re.captures(line) {
                let rule_id = caps[1].to_string();
                push_constraint(
                    &mut seen,
                    &mut source_constraints,
                    &mut constraints,
                    format!("rule:{rule_id}"),
                    rule_id,
                );
            } else if let Some(caps) = bullet_re.captures(line)
                && normative_re.is_match(&caps[1])
            {
                let label = caps[1].trim().to_string();
                let normalized = label
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ")
                    .to_ascii_lowercase();
                push_constraint(
                    &mut seen,
                    &mut source_constraints,
                    &mut constraints,
                    format!("text:{normalized}"),
                    label,
                );
            }
        }
        if !source_constraints.is_empty() {
            reports.push(SourceReport {
                path: path.clone(),
                kind: kind.clone(),
                count: source_constraints.len(),
            });
        }
    }
    (reports, constraints)
}

fn push_constraint(
    seen: &mut HashSet<String>,
    source_constraints: &mut Vec<Constraint>,
    constraints: &mut Vec<Constraint>,
    key: String,
    label: String,
) {
    if !seen.insert(key.clone()) {
        return;
    }
    let constraint = Constraint { key, label };
    source_constraints.push(constraint.clone());
    constraints.push(constraint);
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
    fn frontmatter_paths_gate_path_scoped_rules() {
        let text = "---\npaths: src/*.rs, docs/**\n---\n- Must verify changes\n";

        assert!(!matches_task_path(text, &[]));
        assert!(matches_task_path(text, &["src/main.rs".to_string()]));
        assert!(matches_task_path(text, &["docs/spec.md".to_string()]));
        assert!(!matches_task_path(text, &["tests/main.rs".to_string()]));
    }

    #[test]
    fn count_constraints_dedupes_rules_and_ignores_tables_and_fences() {
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
    fn status_thresholds_are_strictly_greater_than_limits() {
        assert_eq!(status_for(15, 15, 30), "ok");
        assert_eq!(status_for(16, 15, 30), "warn");
        assert_eq!(status_for(31, 15, 30), "block");
    }
}
