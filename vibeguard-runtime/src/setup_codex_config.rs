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
        ConfigStatus::Legacy => {
            println!("LEGACY");
            std::process::exit(1);
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

pub fn remove_legacy_mcp(args: &[String]) -> SetupResult<()> {
    if args.len() != 1 {
        return Err(
            "Usage: vibeguard-runtime setup-codex-config-remove-legacy-mcp <config-file>".into(),
        );
    }
    let path = Path::new(&args[0]);
    if !path.exists() {
        println!("SKIP");
        return Ok(());
    }
    let old = std::fs::read_to_string(path)?;
    let (new, changed) = remove_legacy_vibeguard_mcp(&old)?;
    if !changed {
        println!("SKIP");
        return Ok(());
    }
    if new.is_empty() {
        std::fs::remove_file(path)?;
    } else {
        write_text_atomic(path, &new)?;
    }
    println!("CHANGED");
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
enum ConfigStatus {
    Ok,
    Legacy,
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
    features.remove("codex_hooks");
    features["hooks"] = value(true);
    let after = normalized_doc_string(&doc);
    Ok((after.clone(), after != before))
}

fn remove_legacy_vibeguard_mcp(text: &str) -> SetupResult<(String, bool)> {
    let mut doc = parse_document(text)?;
    let before = normalized_doc_string(&doc);
    let mut remove_mcp_servers = false;
    if let Some(mcp_servers) = doc.get_mut("mcp_servers") {
        let table = mcp_servers
            .as_table_mut()
            .ok_or("config.toml [mcp_servers] must be a table")?;
        table.remove("vibeguard");
        remove_mcp_servers = table.is_empty();
    }
    if remove_mcp_servers {
        doc.as_table_mut().remove("mcp_servers");
    }
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
    if features.get("codex_hooks").is_some() {
        return ConfigStatus::Legacy;
    }
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
        let (text, changed) = ensure_hooks_enabled("[features]\ncodex_hooks = true\nx = 1\n")?;
        assert!(changed);
        assert!(text.contains("hooks = true"));
        assert!(!text.contains("codex_hooks"));
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

    #[test]
    fn removes_legacy_mcp_structurally() -> SetupResult<()> {
        let text = "[mcp_servers.vibeguard]\ncommand = \"node\"\n\n[mcp_servers.other]\ncommand = \"keep\"\n";
        let (updated, changed) = remove_legacy_vibeguard_mcp(text)?;
        assert!(changed);
        assert!(!updated.contains("vibeguard"));
        assert!(updated.contains("[mcp_servers.other]"));
        Ok(())
    }
}
