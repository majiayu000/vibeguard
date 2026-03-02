use std::path::PathBuf;

use anyhow::Result;

#[derive(Debug, Clone)]
pub enum Severity {
    Critical,
    High,
    Medium,
    Low,
}

impl std::fmt::Display for Severity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Severity::Critical => write!(f, "critical"),
            Severity::High => write!(f, "high"),
            Severity::Medium => write!(f, "medium"),
            Severity::Low => write!(f, "low"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Rule {
    pub id: String,
    pub title: String,
    pub severity: Severity,
    pub body: String,
    pub source: String,
    pub paths: Vec<String>,
}

pub struct RuleEngine {
    rules: Vec<Rule>,
}

impl RuleEngine {
    pub fn new() -> Self {
        Self { rules: Vec::new() }
    }

    pub fn rules(&self) -> &[Rule] {
        &self.rules
    }

    pub fn load(&mut self, _dir: &std::path::Path) -> Result<()> {
        self.load_builtin()?;
        Ok(())
    }

    fn load_builtin(&mut self) -> Result<()> {
        let builtin_rules: &[(&str, &str)] = &[
            (
                "golden-principles.md",
                include_str!("../../../rules/golden-principles.md"),
            ),
            (
                "common/coding-style.md",
                include_str!("../../../rules/claude-rules/common/coding-style.md"),
            ),
            (
                "common/data-consistency.md",
                include_str!("../../../rules/claude-rules/common/data-consistency.md"),
            ),
            (
                "common/security.md",
                include_str!("../../../rules/claude-rules/common/security.md"),
            ),
            (
                "rust/quality.md",
                include_str!("../../../rules/claude-rules/rust/quality.md"),
            ),
            (
                "typescript/quality.md",
                include_str!("../../../rules/claude-rules/typescript/quality.md"),
            ),
            (
                "python/quality.md",
                include_str!("../../../rules/claude-rules/python/quality.md"),
            ),
            (
                "go/quality.md",
                include_str!("../../../rules/claude-rules/golang/quality.md"),
            ),
            (
                "universal.md",
                include_str!("../../../rules/universal.md"),
            ),
            (
                "rust.md",
                include_str!("../../../rules/rust.md"),
            ),
            (
                "security.md",
                include_str!("../../../rules/security.md"),
            ),
            (
                "typescript.md",
                include_str!("../../../rules/typescript.md"),
            ),
            (
                "python.md",
                include_str!("../../../rules/python.md"),
            ),
            (
                "go.md",
                include_str!("../../../rules/go.md"),
            ),
        ];
        for (name, content) in builtin_rules {
            self.parse_rule_file(&PathBuf::from(name), content)?;
        }
        Ok(())
    }

    fn parse_rule_file(&mut self, source: &PathBuf, content: &str) -> Result<()> {
        let (frontmatter_paths, body) = parse_frontmatter(content);
        let source_str = source.display().to_string();

        for section in split_sections(body) {
            if let Some(rule) = parse_section(&section, &source_str, &frontmatter_paths) {
                self.rules.push(rule);
            }
        }

        Ok(())
    }
}

fn parse_frontmatter(content: &str) -> (Vec<String>, &str) {
    let trimmed = content.trim_start();
    if !trimmed.starts_with("---") {
        return (Vec::new(), content);
    }

    let after_first = &trimmed[3..];
    let end = match after_first.find("---") {
        Some(pos) => pos,
        None => return (Vec::new(), content),
    };

    let frontmatter_block = &after_first[..end];
    let body = &after_first[end + 3..];
    let body = body.strip_prefix('\n').unwrap_or(body);

    let mut paths = Vec::new();
    for line in frontmatter_block.lines() {
        let line = line.trim();
        if let Some(value) = line.strip_prefix("paths:") {
            let value = value.trim();
            for p in value.split(',') {
                let p = p.trim();
                if !p.is_empty() {
                    paths.push(p.to_string());
                }
            }
        }
    }

    (paths, body)
}

struct Section {
    heading: String,
    body: String,
}

fn split_sections(content: &str) -> Vec<Section> {
    let mut sections = Vec::new();
    let mut current_heading = String::new();
    let mut current_body = String::new();

    for line in content.lines() {
        if line.starts_with("## ") {
            if !current_heading.is_empty() {
                sections.push(Section {
                    heading: current_heading,
                    body: current_body.trim().to_string(),
                });
            }
            current_heading = line[3..].to_string();
            current_body = String::new();
        } else if !current_heading.is_empty() {
            current_body.push_str(line);
            current_body.push('\n');
        }
    }

    if !current_heading.is_empty() {
        sections.push(Section {
            heading: current_heading,
            body: current_body.trim().to_string(),
        });
    }

    sections
}

fn parse_section(
    section: &Section,
    source: &str,
    frontmatter_paths: &[String],
) -> Option<Rule> {
    let heading = &section.heading;

    let (id, title, severity) = parse_heading(heading)?;

    Some(Rule {
        id,
        title,
        severity,
        body: section.body.clone(),
        source: source.to_string(),
        paths: frontmatter_paths.to_vec(),
    })
}

fn parse_heading(heading: &str) -> Option<(String, String, Severity)> {
    // Format: "ID: Title (severity)" or "ID: Title"
    // Examples:
    //   "GP-01: 先搜后写（严重）"
    //   "SEC-01: SQL/NoSQL/OS 命令注入（严重）"
    //   "RS-03: unwrap() 在非测试代码中（中）"
    //   "U-01: 不修改公开 API 签名（严格）"

    let colon_pos = heading.find(':')?;
    let id_part = heading[..colon_pos].trim();

    // Validate ID pattern: PREFIX-NN
    if !is_valid_rule_id(id_part) {
        return None;
    }

    let rest = heading[colon_pos + 1..].trim();

    let severity = detect_severity(rest);
    let title = strip_severity_suffix(rest);

    Some((id_part.to_string(), title, severity))
}

fn is_valid_rule_id(id: &str) -> bool {
    let prefixes = [
        "GP-", "SEC-", "U-", "RS-", "TS-", "PY-", "GO-", "CS-",
    ];
    if !prefixes.iter().any(|p| id.starts_with(p)) {
        return false;
    }
    let dash_pos = match id.rfind('-') {
        Some(p) => p,
        None => return false,
    };
    let num_part = &id[dash_pos + 1..];
    !num_part.is_empty() && num_part.chars().all(|c| c.is_ascii_digit())
}

fn detect_severity(text: &str) -> Severity {
    let lower = text.to_lowercase();

    // Check for severity markers in both English and Chinese
    if lower.contains("(critical)")
        || lower.contains("（严重）")
        || lower.contains("(严重)")
        || lower.contains("（critical）")
    {
        return Severity::Critical;
    }
    if lower.contains("(high)")
        || lower.contains("（高）")
        || lower.contains("(高)")
        || lower.contains("（high）")
    {
        return Severity::High;
    }
    if lower.contains("(medium)")
        || lower.contains("（中）")
        || lower.contains("(中)")
        || lower.contains("（medium）")
    {
        return Severity::Medium;
    }
    if lower.contains("(low)")
        || lower.contains("（低）")
        || lower.contains("(低)")
        || lower.contains("（low）")
    {
        return Severity::Low;
    }

    // Also check for standalone severity words (e.g. in table format)
    if lower.contains("严重") || lower.contains("critical") {
        return Severity::Critical;
    }
    if lower.contains("严格") {
        return Severity::High;
    }
    if lower.contains("高") || lower.contains("high") {
        return Severity::High;
    }
    if lower.contains("中") || lower.contains("medium") {
        return Severity::Medium;
    }
    if lower.contains("低") || lower.contains("low") {
        return Severity::Low;
    }

    Severity::Medium
}

fn strip_severity_suffix(text: &str) -> String {
    let text = text.trim();

    // Strip trailing severity markers like （严重）, (high), etc.
    let patterns = [
        "（严重）", "（高）", "（中）", "（低）", "（严格）",
        "(critical)", "(high)", "(medium)", "(low)",
        "(严重)", "(高)", "(中)", "(低)", "(严格)",
    ];

    for pat in &patterns {
        if let Some(stripped) = text.strip_suffix(pat) {
            return stripped.trim().to_string();
        }
    }

    text.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_load_builtin_rules() {
        let mut engine = RuleEngine::new();
        engine.load_builtin().expect("load_builtin should succeed");
        let count = engine.rules().len();
        assert!(
            count >= 40,
            "expected >= 40 rules, got {count}"
        );
    }

    #[test]
    fn test_parse_heading_gp() {
        let (id, title, _) =
            parse_heading("GP-01: 先搜后写（严重）").expect("should parse");
        assert_eq!(id, "GP-01");
        assert_eq!(title, "先搜后写");
    }

    #[test]
    fn test_parse_heading_sec() {
        let (id, title, _) =
            parse_heading("SEC-01: SQL/NoSQL/OS 命令注入（严重）").expect("should parse");
        assert_eq!(id, "SEC-01");
        assert_eq!(title, "SQL/NoSQL/OS 命令注入");
    }

    #[test]
    fn test_parse_heading_rs() {
        let (id, title, _) =
            parse_heading("RS-03: unwrap() 在非测试代码中（中）").expect("should parse");
        assert_eq!(id, "RS-03");
        assert_eq!(title, "unwrap() 在非测试代码中");
    }

    #[test]
    fn test_parse_heading_u() {
        let (id, title, _) =
            parse_heading("U-01: 不修改公开 API 签名（严格）").expect("should parse");
        assert_eq!(id, "U-01");
        assert_eq!(title, "不修改公开 API 签名");
    }

    #[test]
    fn test_frontmatter_parsing() {
        let content = "---\npaths: **/*.rs,**/Cargo.toml\n---\n# Title\n\n## RS-01: Test（高）\nbody";
        let (paths, body) = parse_frontmatter(content);
        assert_eq!(paths, vec!["**/*.rs", "**/Cargo.toml"]);
        assert!(body.contains("## RS-01"));
    }

    #[test]
    fn test_frontmatter_absent() {
        let content = "# Title\n\n## RS-01: Test（高）\nbody";
        let (paths, body) = parse_frontmatter(content);
        assert!(paths.is_empty());
        assert_eq!(body, content);
    }

    #[test]
    fn test_is_valid_rule_id() {
        assert!(is_valid_rule_id("GP-01"));
        assert!(is_valid_rule_id("SEC-10"));
        assert!(is_valid_rule_id("U-24"));
        assert!(is_valid_rule_id("RS-13"));
        assert!(is_valid_rule_id("TS-12"));
        assert!(is_valid_rule_id("PY-07"));
        assert!(is_valid_rule_id("GO-12"));
        assert!(!is_valid_rule_id("INVALID"));
        assert!(!is_valid_rule_id("XX-01"));
    }

    #[test]
    fn test_severity_detection() {
        assert!(matches!(detect_severity("test（严重）"), Severity::Critical));
        assert!(matches!(detect_severity("test（高）"), Severity::High));
        assert!(matches!(detect_severity("test（中）"), Severity::Medium));
        assert!(matches!(detect_severity("test（低）"), Severity::Low));
        assert!(matches!(detect_severity("test (critical)"), Severity::Critical));
        assert!(matches!(detect_severity("test (high)"), Severity::High));
        assert!(matches!(detect_severity("test（严格）"), Severity::High));
    }
}
