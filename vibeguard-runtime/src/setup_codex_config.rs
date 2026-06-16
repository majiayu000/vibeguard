use crate::setup_support::{SetupResult, write_text_atomic};
use std::path::Path;
use toml_edit::{DocumentMut, Item, Table, value};

pub fn enable_hooks(args: &[String]) -> SetupResult<()> {
    if args.len() != 1 {
        return Err(
            "Usage: vibeguard-runtime setup-codex-config-enable-hooks <config-file>".into(),
        );
    }
    let path = Path::new(&args[0]);
    let old = if path.exists() {
        std::fs::read_to_string(path)?
    } else {
        String::new()
    };
    let (new, changed) = ensure_hooks_enabled(&old)?;
    if changed || !path.exists() {
        write_text_atomic(path, &new)?;
        println!("CHANGED");
    } else {
        println!("SKIP");
    }
    Ok(())
}

pub fn check_hooks(args: &[String]) -> SetupResult<()> {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime setup-codex-config-check-hooks <config-file>".into());
    }
    let path = Path::new(&args[0]);
    if !path.exists() {
        println!("MISSING");
        std::process::exit(1);
    }
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(_) => {
            println!("INVALID");
            std::process::exit(1);
        }
    };
    match check_hooks_status(&text) {
        ConfigStatus::Ok => {
            println!("OK");
            Ok(())
        }
        ConfigStatus::Missing => {
            println!("MISSING");
            std::process::exit(1);
        }
        ConfigStatus::Invalid => {
            println!("INVALID");
            std::process::exit(1);
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
enum ConfigStatus {
    Ok,
    Missing,
    Invalid,
}

fn ensure_hooks_enabled(text: &str) -> SetupResult<(String, bool)> {
    let mut doc = parse_document(text)?;
    let before = normalized_doc_string(&doc);
    ensure_table(&mut doc, "features")?;
    let features = doc["features"]
        .as_table_mut()
        .ok_or("config.toml [features] must be a table")?;
    features["hooks"] = value(true);
    let after = normalized_doc_string(&doc);
    Ok((after.clone(), after != before))
}

fn check_hooks_status(text: &str) -> ConfigStatus {
    let Ok(doc) = parse_document(text) else {
        return ConfigStatus::Invalid;
    };
    let Some(features) = doc.get("features").and_then(Item::as_table) else {
        return ConfigStatus::Missing;
    };
    let hooks_true = features
        .get("hooks")
        .and_then(Item::as_value)
        .and_then(|item| item.as_bool())
        .unwrap_or(false);
    if hooks_true {
        ConfigStatus::Ok
    } else {
        ConfigStatus::Missing
    }
}

fn parse_document(text: &str) -> SetupResult<DocumentMut> {
    Ok(text.parse::<DocumentMut>()?)
}

fn ensure_table(doc: &mut DocumentMut, key: &str) -> SetupResult<()> {
    if !doc.as_table().contains_key(key) {
        doc[key] = Item::Table(Table::new());
    }
    if doc[key].as_table().is_none() {
        return Err(format!("config.toml [{key}] must be a table").into());
    }
    Ok(())
}

fn normalized_doc_string(doc: &DocumentMut) -> String {
    let mut text = doc.to_string();
    if !text.is_empty() && !text.ends_with('\n') {
        text.push('\n');
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enables_hooks_in_existing_features() -> SetupResult<()> {
        let (text, changed) = ensure_hooks_enabled("[features]\nx = 1\n")?;
        assert!(changed);
        assert!(text.contains("hooks = true"));
        Ok(())
    }

    #[test]
    fn detects_invalid_table() {
        assert_eq!(
            check_hooks_status("[features\nhooks = true\n"),
            ConfigStatus::Invalid
        );
    }

    #[test]
    fn detects_invalid_bare_key() {
        assert_eq!(
            check_hooks_status("not valid toml =\n[features]\nhooks = true\n"),
            ConfigStatus::Invalid
        );
    }

    #[test]
    fn preserves_hash_inside_strings() -> SetupResult<()> {
        let text = "title = \"a # b\"\n[features]\nhooks = false # old\n";
        let (updated, changed) = ensure_hooks_enabled(text)?;
        assert!(changed);
        assert!(updated.contains("title = \"a # b\""));
        assert_eq!(check_hooks_status(&updated), ConfigStatus::Ok);
        Ok(())
    }
}
