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

fn search<'a>(rules: &'a [Rule], query: &str) -> Result<Vec<&'a Rule>> {
    let terms: Vec<_> = query.split_whitespace().map(str::to_lowercase).collect();
    if terms.is_empty() {
        return Err("rules --search needs at least one nonempty term".into());
    }
    let mut matches: Vec<_> = rules
        .iter()
        .filter_map(|rule| {
            let text =
                format!("{} {} {} {}", rule.id, rule.title, rule.source, rule.body).to_lowercase();
            if !terms.iter().all(|term| text.contains(term)) {
                return None;
            }
            let title = rule.title.to_lowercase();
            let title_matches = terms.iter().filter(|term| title.contains(*term)).count();
            Some((title_matches, rule))
        })
        .collect();
    matches.sort_by(|(left_score, left), (right_score, right)| {
        right_score
            .cmp(left_score)
            .then_with(|| left.id.cmp(&right.id))
    });
    Ok(matches.into_iter().map(|(_, rule)| rule).collect())
}

pub fn run(args: &[String]) -> Result<u8> {
    if let [flag, query] = args
        && flag == "--search"
    {
        let rules = catalog()?;
        let selected = search(&rules, query)?;
        if selected.is_empty() {
            return Err("no rules match the search terms".into());
        }
        for rule in selected.iter().take(10) {
            println!("{}\t{}\t{}", rule.id, rule.source, rule.title);
        }
        if selected.len() > 10 {
            eprintln!(
                "Showing 10 of {} matches; refine the search terms.",
                selected.len()
            );
        }
        return Ok(0);
    }
    if args.len() > 1 {
        return Err("usage: rules [ID|category|--json|--core|--search TEXT]".into());
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

    #[test]
    fn keyword_search_matches_all_terms_and_prefers_titles() {
        let rules = vec![
            Rule {
                id: "T-01".into(),
                title: "Background work".into(),
                severity: "review".into(),
                source: "rust/quality.md".into(),
                body: "Preserve cancellation errors.".into(),
            },
            Rule {
                id: "T-02".into(),
                title: "Cancellation".into(),
                severity: "review".into(),
                source: "rust/quality.md".into(),
                body: "Propagate errors.".into(),
            },
            Rule {
                id: "T-03".into(),
                title: "Errors".into(),
                severity: "review".into(),
                source: "python/quality.md".into(),
                body: "Preserve exceptions.".into(),
            },
        ];
        let found = search(&rules, "CANCELLATION errors").unwrap();
        assert_eq!(
            found
                .iter()
                .map(|rule| rule.id.as_str())
                .collect::<Vec<_>>(),
            ["T-02", "T-01"]
        );
        assert_eq!(search(&rules, "PYTHON exceptions").unwrap()[0].id, "T-03");
        assert!(search(&rules, "cancellation python").unwrap().is_empty());
        assert!(search(&rules, " \t ").is_err());
    }
}
