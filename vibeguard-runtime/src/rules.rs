use crate::{Result, print_json};
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize, Serialize)]
pub struct Rule {
    pub id: String,
    pub title: String,
    pub severity: String,
    pub source: String,
    pub body: String,
}

pub fn catalog() -> Result<Vec<Rule>> {
    Ok(serde_json::from_str(include_str!(
        "../../rules/rule-descriptions.json"
    ))?)
}

pub const CORE: &str = include_str!("../../claude-md/vibeguard-rules.md");

pub fn run(args: &[String]) -> Result<u8> {
    if args.len() > 1 {
        return Err("rules takes at most one ID, category, --json or --core".into());
    }
    let rules = catalog()?;
    match args.first().map(String::as_str) {
        Some("--json") => print_json(&rules)?,
        Some("--core") => print!("{CORE}"),
        None => {
            for rule in rules {
                println!(
                    "{}\t{}\t{}",
                    rule.id,
                    rule.source.split('/').next().unwrap_or(""),
                    rule.title
                );
            }
        }
        Some(query) => {
            let selected: Vec<_> = rules
                .iter()
                .filter(|r| r.id == query || r.source.split('/').next() == Some(query))
                .collect();
            if selected.is_empty() {
                return Err(format!("no rule or category named {query}").into());
            }
            for rule in selected {
                println!(
                    "## {}: {} ({})\n{}\n",
                    rule.id, rule.title, rule.severity, rule.body
                );
            }
        }
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn embedded_rules_have_unique_ids_and_real_bodies() {
        let rules = catalog().unwrap();
        let ids: std::collections::BTreeSet<_> = rules.iter().map(|r| &r.id).collect();
        assert_eq!(rules.len(), ids.len());
        assert!(!rules.is_empty());
        for rule in rules {
            assert!(!rule.body.trim().is_empty(), "{}", rule.id);
        }
    }
}
