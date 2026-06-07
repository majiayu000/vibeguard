use crate::setup_support::SetupResult;
use serde_json::Value;
use std::collections::BTreeSet;
use std::path::{Component, Path};

const MANIFEST_REL: &str = "schemas/install-modules.json";

#[derive(Clone, Debug, PartialEq, Eq)]
struct RuleLink {
    source: String,
    dest_rel: String,
    label: String,
}

pub fn skill_links(args: &[String]) -> SetupResult<()> {
    if args.len() != 2 {
        return Err(
            "Usage: vibeguard-runtime setup-manifest-skill-links <repo-dir> <target>".into(),
        );
    }
    for (source, skill) in manifest_skill_links(Path::new(&args[0]), &args[1])? {
        println!("{source}\t{skill}");
    }
    Ok(())
}

pub fn rule_links(args: &[String]) -> SetupResult<()> {
    if args.is_empty() || args.len() > 2 {
        return Err(
            "Usage: vibeguard-runtime setup-manifest-rule-links <repo-dir> [languages]".into(),
        );
    }
    let languages = args.get(1).map(String::as_str).unwrap_or("");
    for link in manifest_rule_links(Path::new(&args[0]), languages)? {
        println!("{}\t{}\t{}", link.source, link.dest_rel, link.label);
    }
    Ok(())
}

pub fn rule_labels(args: &[String]) -> SetupResult<()> {
    if args.is_empty() || args.len() > 2 {
        return Err(
            "Usage: vibeguard-runtime setup-manifest-rule-labels <repo-dir> [languages]".into(),
        );
    }
    let languages = args.get(1).map(String::as_str).unwrap_or("");
    let mut seen = BTreeSet::new();
    for link in manifest_rule_links(Path::new(&args[0]), languages)? {
        if seen.insert(link.label.clone()) {
            println!("{}", link.label);
        }
    }
    Ok(())
}

pub fn manifest_skill_links(repo_dir: &Path, target: &str) -> SetupResult<Vec<(String, String)>> {
    let manifest = load_manifest(repo_dir)?;
    let modules = manifest
        .get("modules")
        .and_then(Value::as_array)
        .ok_or("manifest modules must be a list")?;
    let mut links = Vec::new();
    for module in modules {
        let Some(object) = module.as_object() else {
            return Err("manifest module entry is not an object".into());
        };
        if object.get("kind").and_then(Value::as_str) != Some("skills")
            || object.get("target").and_then(Value::as_str) != Some(target)
        {
            continue;
        }
        let module_id = object
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or("<unknown>");
        let paths = object
            .get("paths")
            .and_then(Value::as_array)
            .ok_or_else(|| format!("module {module_id}: paths must be a list"))?;
        for path in paths {
            let Some(path_text) = path.as_str() else {
                return Err(format!("module {module_id}: non-string path entry").into());
            };
            let source = normalize_skill_source(path_text, module_id)?;
            let skill = Path::new(&source)
                .file_name()
                .and_then(|name| name.to_str())
                .ok_or_else(|| {
                    format!(
                        "module {module_id}: skill path must name a skill directory: {path_text}"
                    )
                })?
                .to_string();
            links.push((source, skill));
        }
    }
    Ok(links)
}

fn manifest_rule_links(repo_dir: &Path, languages: &str) -> SetupResult<Vec<RuleLink>> {
    let manifest = load_manifest(repo_dir)?;
    let selected = language_filter(languages);
    let modules = manifest
        .get("modules")
        .and_then(Value::as_array)
        .ok_or("manifest modules must be a list")?;
    let mut links = Vec::new();
    for module in modules {
        let Some(object) = module.as_object() else {
            return Err("manifest module entry is not an object".into());
        };
        if object.get("kind").and_then(Value::as_str) != Some("rules") {
            continue;
        }
        let module_id = object
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or("<unknown>");
        let module_languages = module_languages(object, module_id)?;
        if !selected.is_empty()
            && !module_languages.is_empty()
            && selected.is_disjoint(&module_languages)
        {
            continue;
        }
        let paths = object
            .get("paths")
            .and_then(Value::as_array)
            .ok_or_else(|| format!("module {module_id}: paths must be a list"))?;
        for path in paths {
            let Some(path_text) = path.as_str() else {
                return Err(format!("module {module_id}: non-string rule path").into());
            };
            let link = normalize_rule_source(repo_dir, path_text, module_id)?;
            links.push(link);
        }
    }
    Ok(links)
}

fn load_manifest(repo_dir: &Path) -> SetupResult<Value> {
    let text = std::fs::read_to_string(repo_dir.join(MANIFEST_REL))?;
    let value: Value = serde_json::from_str(&text)?;
    if !value.is_object() {
        return Err("manifest root must be an object".into());
    }
    Ok(value)
}

fn language_filter(languages: &str) -> BTreeSet<String> {
    languages
        .split(',')
        .filter_map(|part| {
            let normalized = normalize_language(part);
            (!normalized.is_empty()).then_some(normalized)
        })
        .collect()
}

fn module_languages(
    module: &serde_json::Map<String, Value>,
    module_id: &str,
) -> SetupResult<BTreeSet<String>> {
    let mut out = BTreeSet::new();
    let Some(value) = module.get("languages") else {
        return Ok(out);
    };
    let Some(items) = value.as_array() else {
        return Err(format!("module {module_id}: languages must be a list").into());
    };
    for item in items {
        let Some(text) = item.as_str() else {
            return Err(format!("module {module_id}: non-string language entry").into());
        };
        let normalized = normalize_language(text);
        if !normalized.is_empty() {
            out.insert(normalized);
        }
    }
    Ok(out)
}

fn normalize_language(value: &str) -> String {
    let language = value.trim().to_ascii_lowercase();
    if language == "golang" {
        "go".to_string()
    } else {
        language
    }
}

fn normalize_skill_source(path_text: &str, module_id: &str) -> SetupResult<String> {
    let source = path_text.trim_end_matches('/');
    if source.is_empty() || source.contains('\\') || source.starts_with('/') {
        return Err(
            format!("module {module_id}: skill path must be repo-relative: {path_text}").into(),
        );
    }
    if has_parent_component(source) {
        return Err(
            format!("module {module_id}: skill path must not contain '..': {path_text}").into(),
        );
    }
    if Path::new(source).file_name().is_none() {
        return Err(format!(
            "module {module_id}: skill path must name a skill directory: {path_text}"
        )
        .into());
    }
    Ok(source.to_string())
}

fn normalize_rule_source(
    repo_dir: &Path,
    path_text: &str,
    module_id: &str,
) -> SetupResult<RuleLink> {
    let source = path_text.trim_end_matches('/');
    if source.is_empty() || source.contains('\\') || source.starts_with('/') {
        return Err(
            format!("module {module_id}: rule path must be repo-relative: {path_text}").into(),
        );
    }
    if has_parent_component(source) {
        return Err(
            format!("module {module_id}: rule path must not contain '..': {path_text}").into(),
        );
    }
    if !source.ends_with(".md") {
        return Err(
            format!("module {module_id}: rule path must be a Markdown file: {path_text}").into(),
        );
    }
    let prefix = "rules/claude-rules/";
    let Some(dest_rel) = source.strip_prefix(prefix) else {
        return Err(format!(
            "module {module_id}: rule path must live under rules/claude-rules/: {path_text}"
        )
        .into());
    };
    let label = dest_rel
        .split('/')
        .next()
        .filter(|part| !part.is_empty())
        .ok_or_else(|| {
            format!("module {module_id}: rule path must include a rule subdirectory: {path_text}")
        })?;
    if !repo_dir.join(source).is_file() {
        return Err(format!("module {module_id}: missing rule path {source}").into());
    }
    Ok(RuleLink {
        source: source.to_string(),
        dest_rel: dest_rel.to_string(),
        label: label.to_string(),
    })
}

fn has_parent_component(path_text: &str) -> bool {
    Path::new(path_text)
        .components()
        .any(|component| matches!(component, Component::ParentDir))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn language_filter_normalizes_golang() {
        let filter = language_filter("rust,golang, python");
        assert!(filter.contains("rust"));
        assert!(filter.contains("go"));
        assert!(filter.contains("python"));
    }

    #[test]
    fn rejects_parent_skill_path() {
        assert!(normalize_skill_source("../skills/vibeguard", "x").is_err());
    }
}
