#[cfg(test)]
use super::*;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn temp_post_write_project(name: &str) -> PathBuf {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "vibeguard_post_write_{name}_{}_{}",
        std::process::id(),
        unique
    ));
    fs::create_dir_all(root.join(".git")).expect("git marker should be created");
    root
}

fn config() -> PostWriteConfig {
    PostWriteConfig {
        base_limit: 800,
        warn_limit: 400,
        max_scan_files: 5000,
        max_scan_defs: 20,
        max_matches: 5,
    }
}

#[test]
fn detects_same_name_and_definition_duplicates() {
    let root = temp_post_write_project("duplicates");
    let existing = root.join("src").join("existing");
    let new_dir = root.join("src").join("new");
    fs::create_dir_all(&existing).expect("existing dir");
    fs::create_dir_all(&new_dir).expect("new dir");
    fs::write(
        existing.join("service.py"),
        "def processOrder():\n    return 1\n",
    )
    .expect("existing file");
    let file_path = new_dir.join("service.py");
    let outcome = evaluate_post_write(
        file_path.to_string_lossy().as_ref(),
        "def processOrder():\n    return 2\n",
        config(),
    );
    let PostWriteOutcome::Warn { warnings } = outcome else {
        panic!("expected warning");
    };
    assert!(warnings.contains("duplicate filename"), "{warnings}");
    assert!(warnings.contains("processOrder"), "{warnings}");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn go_same_name_is_not_duplicate_filename() {
    let root = temp_post_write_project("go_same_name");
    let foo = root.join("internal").join("foo");
    let cli = root.join("internal").join("cli");
    fs::create_dir_all(&foo).expect("foo dir");
    fs::create_dir_all(&cli).expect("cli dir");
    fs::write(
        foo.join("config.go"),
        "package foo\n\ntype FooConfig struct{}\n",
    )
    .expect("foo config");
    let file_path = cli.join("config.go");
    let outcome = evaluate_post_write(
        file_path.to_string_lossy().as_ref(),
        "package cli\n\ntype CLIConfig struct{}\n",
        config(),
    );
    assert_eq!(outcome, PostWriteOutcome::Pass { reason: "" });
    let _ = fs::remove_dir_all(root);
}

#[test]
fn scan_budget_degrades_duplicate_definitions() {
    let root = temp_post_write_project("budget");
    let src = root.join("src");
    fs::create_dir_all(&src).expect("src dir");
    fs::write(
        src.join("existing.py"),
        "def keepExisting():\n    return 1\n",
    )
    .expect("existing file");
    let file_path = src.join("new.py");
    let mut cfg = config();
    cfg.max_scan_files = 0;
    let outcome = evaluate_post_write(
        file_path.to_string_lossy().as_ref(),
        "def keepExisting():\n    return 2\n",
        cfg,
    );
    let PostWriteOutcome::Warn { warnings } = outcome else {
        panic!("expected budget warning");
    };
    assert!(
        warnings.contains("deep duplicate scan skipped"),
        "{warnings}"
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn same_name_detection_survives_scan_budget() {
    let root = temp_post_write_project("same_name_budget");
    let old_dir = root.join("old");
    let new_dir = root.join("new");
    fs::create_dir_all(&old_dir).expect("old dir");
    fs::create_dir_all(&new_dir).expect("new dir");
    fs::write(
        old_dir.join("service.py"),
        "def existingThing():\n    return 1\n",
    )
    .expect("old file");
    let file_path = new_dir.join("service.py");
    let mut cfg = config();
    cfg.max_scan_files = 0;

    let outcome = evaluate_post_write(
        file_path.to_string_lossy().as_ref(),
        "def newThing():\n    return 2\n",
        cfg,
    );
    let PostWriteOutcome::Warn { warnings } = outcome else {
        panic!("expected warning");
    };
    assert!(warnings.contains("duplicate filename"), "{warnings}");
    assert!(
        warnings.contains("deep duplicate scan skipped"),
        "{warnings}"
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn go_duplicate_definition_still_warns_without_same_name_warning() {
    let root = temp_post_write_project("go_dup_def");
    let old_dir = root.join("internal").join("foo");
    let new_dir = root.join("internal").join("cli");
    fs::create_dir_all(&old_dir).expect("old dir");
    fs::create_dir_all(&new_dir).expect("new dir");
    fs::write(
        old_dir.join("config.go"),
        "package foo\n\ntype CLIConfig struct{}\n",
    )
    .expect("old file");
    let file_path = new_dir.join("config.go");

    let outcome = evaluate_post_write(
        file_path.to_string_lossy().as_ref(),
        "package cli\n\ntype CLIConfig struct{}\n",
        config(),
    );
    let PostWriteOutcome::Warn { warnings } = outcome else {
        panic!("expected warning");
    };
    assert!(!warnings.contains("duplicate filename"), "{warnings}");
    assert!(warnings.contains("CLIConfig"), "{warnings}");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn stubs_and_u16_are_reported() {
    let root = temp_post_write_project("stub_u16");
    let src = root.join("src");
    fs::create_dir_all(&src).expect("src dir");
    let file_path = src.join("new.py");
    let content = ["pass"; 401].join("\n");
    let outcome = evaluate_post_write(file_path.to_string_lossy().as_ref(), &content, config());
    let PostWriteOutcome::Warn { warnings } = outcome else {
        panic!("expected warnings");
    };
    assert!(warnings.contains("[STUB]"), "{warnings}");
    assert!(warnings.contains("[U-16]"), "{warnings}");
    let _ = fs::remove_dir_all(root);
}
