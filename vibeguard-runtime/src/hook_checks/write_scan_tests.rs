#[cfg(test)]
mod write_scan_tests {
    use super::super::*;
    use std::collections::HashMap;
    use std::fs;
    use std::path::PathBuf;
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
        let combined =
            scan_project_files_with_same_name(&root, target.to_string_lossy().as_ref(), 10, 5);
        assert_eq!(combined.project.count, 1);
        assert!(combined.same_name.matches.is_empty());

        let degraded = scan_project_files(&root, 0);
        assert!(degraded.degraded);
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn same_name_scan_ignores_test_and_fixture_paths() -> TestResult {
        let root = temp_write_scan_project("same_name_test_paths")?;
        fs::create_dir_all(root.join("src").join("new"))?;
        for dir in ["fixtures", "mocks", "testdata"] {
            fs::create_dir_all(root.join(dir))?;
            fs::write(root.join(dir).join("config.rs"), "pub fn fake() {}\n")?;
        }
        fs::write(
            root.join("src").join("config.test.py"),
            "def fake():\n    pass\n",
        )?;
        fs::write(
            root.join("src").join("config_test.py"),
            "def fake():\n    pass\n",
        )?;
        fs::write(root.join("src").join("config.rs"), "pub fn real() {}\n")?;
        let target = root.join("src").join("new").join("config.rs");

        let legacy = scan_same_name_matches(&root, target.to_string_lossy().as_ref(), 10);
        let combined =
            scan_project_files_with_same_name(&root, target.to_string_lossy().as_ref(), 0, 10);

        assert_eq!(
            legacy.matches,
            vec![root.join("src").join("config.rs").to_string_lossy()]
        );
        assert_eq!(
            combined.same_name.matches,
            vec![root.join("src").join("config.rs").to_string_lossy()]
        );
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn combined_scan_preserves_same_name_matches_after_budget_degrades() -> TestResult {
        let root = temp_write_scan_project("same_name_budget")?;
        fs::create_dir_all(root.join("src").join("existing"))?;
        fs::create_dir_all(root.join("src").join("new"))?;
        fs::write(root.join("src").join("existing").join("service.py"), "")?;
        let target = root.join("src").join("new").join("service.py");

        let combined =
            scan_project_files_with_same_name(&root, target.to_string_lossy().as_ref(), 0, 5);

        assert!(combined.project.degraded);
        assert!(
            combined
                .same_name
                .matches
                .iter()
                .any(|path| path.ends_with("existing/service.py")),
            "{combined:?}"
        );
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn duplicate_definition_scan_reads_each_candidate_once_for_all_definitions() -> TestResult {
        let root = temp_write_scan_project("single_pass_defs")?;
        fs::create_dir_all(root.join("src"))?;
        let existing = root.join("src").join("existing.py");
        let helper = root.join("src").join("helper.py");
        fs::write(
            &existing,
            "def firstThing():\n    pass\n\ndef secondThing():\n    pass\n",
        )?;
        fs::write(&helper, "def unrelatedThing():\n    pass\n")?;
        let mut expected_reads = vec![existing.clone(), helper.clone()];
        for index in 0..30 {
            let candidate = root.join("src").join(format!("candidate_{index}.py"));
            fs::write(
                &candidate,
                format!("def unrelatedThing{index}():\n    pass\n"),
            )?;
            expected_reads.push(candidate);
        }
        let scan = scan_project_files(&root, 100);
        let mut reads: HashMap<PathBuf, usize> = HashMap::new();

        let found = duplicate_definition_scan_with_reader(
            &scan.files,
            root.join("src").join("new.py").to_string_lossy().as_ref(),
            "def firstThing():\n    return 1\n\ndef secondThing():\n    return 2\n",
            "py",
            20,
            5,
            |path| {
                *reads.entry(path.to_path_buf()).or_insert(0) += 1;
                fs::read_to_string(path)
            },
        );

        assert_eq!(found.duplicates.len(), 2, "{found:?}");
        assert!(found.duplicates[0].contains("firstThing"), "{found:?}");
        assert!(found.duplicates[1].contains("secondThing"), "{found:?}");
        assert_eq!(reads.len(), expected_reads.len(), "{reads:?}");
        for path in expected_reads {
            assert_eq!(reads.get(&path).copied(), Some(1), "{path:?} {reads:?}");
        }
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
}
