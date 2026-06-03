use super::*;
use std::time::{SystemTime, UNIX_EPOCH};

type TestResult = std::result::Result<(), Box<dyn std::error::Error>>;

fn temp_write_scan_project(name: &str) -> std::io::Result<PathBuf> {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "vibeguard_write_scan_{name}_{}_{}",
        std::process::id(),
        unique
    ));
    fs::create_dir_all(root.join(".git"))?;
    Ok(root)
}

#[test]
fn scan_skips_test_dirs_and_respects_budget() -> TestResult {
    let root = temp_write_scan_project("skip_tests")?;
    fs::create_dir_all(root.join("src"))?;
    fs::create_dir_all(root.join("tests"))?;
    let target = root.join("src").join("lib.py");
    fs::write(&target, "def realThing():\n    pass\n")?;
    fs::write(
        root.join("tests").join("lib.py"),
        "def testThing():\n    pass\n",
    )?;

    let scan = scan_project_files(&root, 10);
    assert_eq!(scan.count, 1);
    assert!(!scan.degraded);
    assert!(
        scan_same_name_matches(&root, target.to_string_lossy().as_ref(), 5)
            .matches
            .is_empty()
    );

    let degraded = scan_project_files(&root, 0);
    assert!(degraded.degraded);
    fs::remove_dir_all(root)?;
    Ok(())
}

#[test]
fn duplicate_definition_matches_same_extension_only() -> TestResult {
    let root = temp_write_scan_project("duplicate_defs")?;
    fs::create_dir_all(root.join("src"))?;
    fs::write(
        root.join("src").join("existing.py"),
        "def sharedName():\n    pass\n",
    )?;
    fs::write(
        root.join("src").join("existing.ts"),
        "function sharedName() {}\n",
    )?;
    let scan = scan_project_files(&root, 10);

    let found = duplicate_definition_scan(
        &scan.files,
        root.join("src").join("new.py").to_string_lossy().as_ref(),
        "def sharedName():\n    return 1\n",
        "py",
        20,
        5,
    );
    assert_eq!(found.duplicates.len(), 1);
    assert!(found.duplicates[0].contains("existing.py"), "{found:?}");
    assert!(!found.duplicates[0].contains("existing.ts"), "{found:?}");
    fs::remove_dir_all(root)?;
    Ok(())
}

#[test]
fn missing_scan_root_marks_incomplete() -> TestResult {
    let root = temp_write_scan_project("missing_root")?;
    let missing = root.join("missing");

    assert!(scan_project_files(&missing, 10).incomplete);
    assert!(scan_same_name_matches(&missing, "new.py", 5).incomplete);

    fs::remove_dir_all(root)?;
    Ok(())
}
