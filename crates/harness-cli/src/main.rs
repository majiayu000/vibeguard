use std::path::PathBuf;

use anyhow::Result;
use harness_rules::engine::RuleEngine;

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 3 {
        print_usage();
        return Ok(());
    }

    let command = &args[1];
    let subcommand = &args[2];

    match (command.as_str(), subcommand.as_str()) {
        ("rule", "load") => {
            let dir = if args.len() > 3 { &args[3] } else { "." };
            cmd_rule_load(&PathBuf::from(dir))?;
        }
        _ => {
            eprintln!("unknown command: {} {}", command, subcommand);
            print_usage();
        }
    }

    Ok(())
}

fn cmd_rule_load(dir: &PathBuf) -> Result<()> {
    let mut engine = RuleEngine::new();
    engine.load(dir)?;

    let rules = engine.rules();
    println!("loaded {} rules from {}", rules.len(), dir.display());
    println!();

    for rule in rules {
        let paths_str = if rule.paths.is_empty() {
            String::from("*")
        } else {
            rule.paths.join(", ")
        };
        println!(
            "  [{severity}] {id}: {title}  (source: {source}, paths: {paths})",
            severity = rule.severity,
            id = rule.id,
            title = rule.title,
            source = rule.source,
            paths = paths_str,
        );
    }

    Ok(())
}

fn print_usage() {
    eprintln!("usage: harness <command> <subcommand> [args]");
    eprintln!();
    eprintln!("commands:");
    eprintln!("  rule load <dir>   Load and display all rules");
}
