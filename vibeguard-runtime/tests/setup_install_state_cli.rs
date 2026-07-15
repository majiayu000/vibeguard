mod common;

use common::{bin, unique_temp_dir};
use serde_json::{Value, json};
use std::fs;
use std::path::Path;
use std::process::Output;

fn run(root: &Path, args: &[&str]) -> Output {
    bin()
        .args(args)
        .env("HOME", root.join("home"))
        .current_dir(root)
        .output()
        .expect("vibeguard-runtime command should run")
}

fn assert_output(output: &Output, code: i32, stdout: &str, stderr: &str) {
    assert_eq!(output.status.code(), Some(code));
    assert_eq!(String::from_utf8_lossy(&output.stdout), stdout);
    assert_eq!(String::from_utf8_lossy(&output.stderr), stderr);
}

fn assert_io_error(output: &Output) {
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.starts_with("vibeguard-runtime error: "));
    assert!(stderr.trim().len() > "vibeguard-runtime error:".len());
}

fn write_json(path: &Path, value: &Value) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("JSON parent should be created");
    }
    fs::write(
        path,
        format!(
            "{}\n",
            serde_json::to_string_pretty(value).expect("fixture should serialize")
        ),
    )
    .expect("JSON fixture should be written");
}

fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).expect("state file should be readable"))
        .expect("state file should contain JSON")
}

fn path_text(path: &Path) -> String {
    path.to_str()
        .expect("temporary paths should be UTF-8")
        .to_string()
}

#[test]
fn setup_state_commands_reject_invalid_arity_with_exact_usage() {
    let root = unique_temp_dir("install_state_arity");
    fs::create_dir_all(root.join("home")).expect("temp root should be created");
    let cases = [
        (
            "setup-state-init",
            "Usage: vibeguard-runtime setup-state-init <state-file> <profile> <languages>",
        ),
        (
            "setup-state-record-file",
            "Usage: vibeguard-runtime setup-state-record-file <state-file> <dest> <source> <type>",
        ),
        (
            "setup-state-record-project-hook",
            "Usage: vibeguard-runtime setup-state-record-project-hook <state-file> <repo-dir> <hook-path> <hook-name>",
        ),
        (
            "setup-state-check-drift",
            "Usage: vibeguard-runtime setup-state-check-drift <state-file>",
        ),
        (
            "setup-state-list",
            "Usage: vibeguard-runtime setup-state-list <state-file>",
        ),
        (
            "setup-state-list-symlinks-under",
            "Usage: vibeguard-runtime setup-state-list-symlinks-under <state-file> <dest-dir>",
        ),
        (
            "setup-state-list-project-hooks",
            "Usage: vibeguard-runtime setup-state-list-project-hooks <state-file>",
        ),
    ];

    for (command, usage) in cases {
        let output = run(&root, &[command]);
        assert_output(
            &output,
            1,
            "",
            &format!("vibeguard-runtime error: {usage}\n"),
        );
    }
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn init_and_record_commands_persist_expected_schema() {
    let root = unique_temp_dir("install_state_record");
    let home = root.join("home");
    let state = root.join("install-state.json");
    fs::create_dir_all(home.join(".vibeguard")).expect("home state dir should be created");
    fs::write(home.join(".vibeguard/repo-path"), " /repo/source \n")
        .expect("repo path should be written");

    let output = run(
        &root,
        &[
            "setup-state-init",
            &path_text(&state),
            "full",
            "rust,python",
        ],
    );
    assert_output(&output, 0, "", "");
    let initialized = read_json(&state);
    assert_eq!(initialized["version"], 1);
    assert_eq!(initialized["profile"], "full");
    assert_eq!(initialized["languages"], json!(["rust", "python"]));
    assert_eq!(initialized["repo_dir"], "/repo/source");
    assert_eq!(initialized["files"], json!({}));
    let installed_at = initialized["installed_at"]
        .as_str()
        .expect("installed_at should be a string");
    assert!(installed_at.len() >= 10);
    assert!(installed_at.chars().all(|ch| ch.is_ascii_digit()));
    assert_eq!(initialized.as_object().unwrap().len(), 6);

    let no_home_state = root.join("no-home-state.json");
    let no_home = bin()
        .args(["setup-state-init", &path_text(&no_home_state), "core", ""])
        .env_remove("HOME")
        .env_remove("USERPROFILE")
        .current_dir(&root)
        .output()
        .expect("no-home setup-state-init should run");
    assert_output(&no_home, 0, "", "");
    assert_eq!(read_json(&no_home_state)["repo_dir"], "");

    let empty_state = root.join("empty-install-state.json");
    let output = run(
        &root,
        &["setup-state-init", &path_text(&empty_state), "core", ""],
    );
    assert_output(&output, 0, "", "");
    let empty_initialized = read_json(&empty_state);
    assert_eq!(empty_initialized["languages"], json!([]));
    assert_eq!(empty_initialized["repo_dir"], "/repo/source");

    let regular = root.join("regular.txt");
    fs::write(&regular, "hello").expect("regular fixture should be written");
    let output = run(
        &root,
        &[
            "setup-state-record-file",
            &path_text(&state),
            &path_text(&regular),
            "generated/regular.txt",
            "copy",
        ],
    );
    assert_output(&output, 0, "", "");

    let link = root.join("linked.txt");
    let output = run(
        &root,
        &[
            "setup-state-record-file",
            &path_text(&state),
            &path_text(&link),
            "generated/linked.txt",
            "symlink",
        ],
    );
    assert_output(&output, 0, "", "");

    let missing = root.join("missing.txt");
    let output = run(
        &root,
        &[
            "setup-state-record-file",
            &path_text(&state),
            &path_text(&missing),
            "generated/missing.txt",
            "copy",
        ],
    );
    assert_output(&output, 0, "", "");

    let repo = root.join("project");
    let hook = repo.join(".git/hooks/pre-commit");
    let output = run(
        &root,
        &[
            "setup-state-record-project-hook",
            &path_text(&state),
            &path_text(&repo),
            &path_text(&hook),
            "pre-commit",
        ],
    );
    assert_output(&output, 0, "", "");

    let recorded = read_json(&state);
    assert_eq!(
        recorded["files"][path_text(&regular)],
        json!({
            "source": "generated/regular.txt",
            "type": "copy",
            "checksum": "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        })
    );
    assert_eq!(
        recorded["files"][path_text(&link)],
        json!({"source": "generated/linked.txt", "type": "symlink"})
    );
    assert_eq!(
        recorded["files"][path_text(&missing)],
        json!({"source": "generated/missing.txt", "type": "copy"})
    );
    assert_eq!(
        recorded["project_hooks"][path_text(&hook)],
        json!({"repo_dir": path_text(&repo), "hook_name": "pre-commit"})
    );
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn record_commands_initialize_missing_state_and_reject_invalid_shapes() {
    let root = unique_temp_dir("install_state_record_errors");
    fs::create_dir_all(root.join("home")).expect("temp root should be created");
    let state = root.join("missing-state.json");
    let dest = root.join("not-created.txt");
    let output = run(
        &root,
        &[
            "setup-state-record-file",
            &path_text(&state),
            &path_text(&dest),
            "source.txt",
            "copy",
        ],
    );
    assert_output(&output, 0, "", "");
    assert_eq!(read_json(&state)["version"], 1);
    assert_eq!(read_json(&state)["files"].as_object().unwrap().len(), 1);

    let hook_state = root.join("missing-hook-state.json");
    let output = run(
        &root,
        &[
            "setup-state-record-project-hook",
            &path_text(&hook_state),
            "/repo",
            "/repo/.git/hooks/pre-commit",
            "pre-commit",
        ],
    );
    assert_output(&output, 0, "", "");
    assert_eq!(read_json(&hook_state)["version"], 1);
    assert_eq!(
        read_json(&hook_state)["project_hooks"]
            .as_object()
            .unwrap()
            .len(),
        1
    );

    let bad_files = root.join("bad-files.json");
    write_json(&bad_files, &json!({"version": 1, "files": []}));
    let output = run(
        &root,
        &[
            "setup-state-record-file",
            &path_text(&bad_files),
            &path_text(&dest),
            "source.txt",
            "copy",
        ],
    );
    assert_output(
        &output,
        1,
        "",
        "vibeguard-runtime error: install-state files must be an object\n",
    );

    let bad_hooks = root.join("bad-hooks.json");
    write_json(
        &bad_hooks,
        &json!({"version": 1, "files": {}, "project_hooks": []}),
    );
    let output = run(
        &root,
        &[
            "setup-state-record-project-hook",
            &path_text(&bad_hooks),
            "/repo",
            "/repo/.git/hooks/pre-commit",
            "pre-commit",
        ],
    );
    assert_output(
        &output,
        1,
        "",
        "vibeguard-runtime error: install-state project_hooks must be an object\n",
    );

    let root_array = root.join("record-root-array.json");
    write_json(&root_array, &json!([]));
    let output = run(
        &root,
        &[
            "setup-state-record-file",
            &path_text(&root_array),
            &path_text(&dest),
            "source.txt",
            "copy",
        ],
    );
    assert_output(
        &output,
        1,
        "",
        "vibeguard-runtime error: install-state root must be an object\n",
    );

    let unsupported = root.join("record-unsupported.json");
    write_json(&unsupported, &json!({"version": 7, "files": {}}));
    let output = run(
        &root,
        &[
            "setup-state-record-file",
            &path_text(&unsupported),
            &path_text(&dest),
            "source.txt",
            "copy",
        ],
    );
    assert_output(
        &output,
        1,
        "",
        "vibeguard-runtime error: Unsupported install-state version: 7 (expected 1)\n",
    );
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn strict_state_readers_surface_missing_invalid_and_io_states() {
    let root = unique_temp_dir("install_state_strict_read");
    fs::create_dir_all(root.join("home")).expect("temp root should be created");
    let missing = root.join("missing.json");
    let output = run(&root, &["setup-state-list", &path_text(&missing)]);
    assert_output(
        &output,
        1,
        "",
        "vibeguard-runtime error: No install state found. Run setup.sh first.\n",
    );

    let malformed = root.join("malformed.json");
    fs::write(&malformed, "{").expect("malformed state should be written");
    let output = run(&root, &["setup-state-list", &path_text(&malformed)]);
    assert_output(
        &output,
        1,
        "",
        "vibeguard-runtime error: EOF while parsing an object at line 1 column 1\n",
    );

    let root_array = root.join("root-array.json");
    write_json(&root_array, &json!([]));
    let output = run(&root, &["setup-state-check-drift", &path_text(&root_array)]);
    assert_output(
        &output,
        1,
        "",
        "vibeguard-runtime error: install-state root must be an object\n",
    );

    let unsupported = root.join("unsupported.json");
    write_json(&unsupported, &json!({"version": 2, "files": {}}));
    let output = run(&root, &["setup-state-list", &path_text(&unsupported)]);
    assert_output(
        &output,
        1,
        "",
        "vibeguard-runtime error: Unsupported install-state version: 2 (expected 1)\n",
    );

    let state_directory = root.join("state-directory");
    fs::create_dir_all(&state_directory).expect("state directory should be created");
    let output = run(
        &root,
        &["setup-state-check-drift", &path_text(&state_directory)],
    );
    assert_io_error(&output);
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn drift_reports_exact_clean_missing_checksum_and_symlink_counts() {
    let root = unique_temp_dir("install_state_drift");
    fs::create_dir_all(root.join("home")).expect("temp root should be created");
    let state = root.join("state.json");
    let output = run(&root, &["setup-state-check-drift", &path_text(&state)]);
    assert_output(&output, 0, "NO_STATE\n", "");

    write_json(&state, &json!({"version": 9, "files": {}}));
    let output = run(&root, &["setup-state-check-drift", &path_text(&state)]);
    assert_output(
        &output,
        0,
        "UNSUPPORTED_STATE_VERSION: 9 (expected 1)\n",
        "",
    );

    let clean = root.join("a-clean.txt");
    let checksum_drift = root.join("b-checksum-drift.txt");
    let missing = root.join("c-missing.txt");
    let regular_instead_of_link = root.join("d-was-symlink.txt");
    let missing_link = root.join("e-missing-link.txt");
    fs::write(&clean, "hello").expect("clean fixture should be written");
    fs::write(&checksum_drift, "changed").expect("drift fixture should be written");
    fs::write(&regular_instead_of_link, "regular").expect("regular fixture should be written");

    let mut files = serde_json::Map::new();
    files.insert(
        path_text(&clean),
        json!({"type":"copy", "checksum":"sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"}),
    );
    files.insert(
        path_text(&checksum_drift),
        json!({"type":"copy", "checksum":"sha256:0000"}),
    );
    files.insert(path_text(&missing), json!({"type":"copy"}));
    files.insert(
        path_text(&regular_instead_of_link),
        json!({"type":"symlink"}),
    );
    files.insert(path_text(&missing_link), json!({"type":"symlink"}));

    #[cfg(unix)]
    {
        use std::os::unix::fs::symlink;
        let clean_link = root.join("f-clean-link.txt");
        symlink(&clean, &clean_link).expect("symlink fixture should be created");
        files.insert(path_text(&clean_link), json!({"type":"symlink"}));
    }

    write_json(
        &state,
        &Value::Object(serde_json::Map::from_iter([
            ("version".to_string(), json!(1)),
            ("files".to_string(), Value::Object(files)),
        ])),
    );
    let output = run(&root, &["setup-state-check-drift", &path_text(&state)]);
    let tracked = if cfg!(unix) { 6 } else { 5 };
    assert_output(
        &output,
        0,
        &format!(
            "DRIFT: {} (checksum mismatch)\nMISSING: {}\nDRIFT: {} (was symlink, now regular file)\nMISSING: {}\n---\nTotal tracked: {tracked}, Missing: 2, Drifted: 2\nSTATUS: DRIFT (2 drifted, 2 missing)\n",
            checksum_drift.display(),
            missing.display(),
            regular_instead_of_link.display(),
            missing_link.display()
        ),
        "",
    );

    let clean_state = root.join("clean-state.json");
    write_json(
        &clean_state,
        &json!({
            "version": 1,
            "files": {
                path_text(&clean): {
                    "type": "copy",
                    "checksum": "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
                }
            }
        }),
    );
    let output = run(
        &root,
        &["setup-state-check-drift", &path_text(&clean_state)],
    );
    assert_output(
        &output,
        0,
        "---\nTotal tracked: 1, Missing: 0, Drifted: 0\nSTATUS: CLEAN\n",
        "",
    );
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn list_renders_default_and_populated_state_exactly() {
    let root = unique_temp_dir("install_state_list");
    fs::create_dir_all(root.join("home")).expect("temp root should be created");
    let state = root.join("state.json");
    write_json(&state, &json!({}));
    let output = run(&root, &["setup-state-list", &path_text(&state)]);
    assert_output(
        &output,
        0,
        "Profile: unknown\nInstalled: unknown\nTracked files: 0\n\n",
        "",
    );

    write_json(
        &state,
        &json!({
            "version": 1,
            "profile": "strict",
            "installed_at": "1700000000",
            "languages": ["rust", 7, "go"],
            "files": {
                "/a-copy": {"type": "copy"},
                "/b-link": {"type": "symlink"},
                "/c-unknown": {}
            }
        }),
    );
    let output = run(&root, &["setup-state-list", &path_text(&state)]);
    assert_output(
        &output,
        0,
        "Profile: strict\nInstalled: 1700000000\nLanguages: rust, go\nTracked files: 3\n\n  [copy   ] /a-copy\n  [symlink] /b-link\n  [?      ] /c-unknown\n",
        "",
    );
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn symlink_cleanup_listing_handles_bad_state_and_filters_paths() {
    let root = unique_temp_dir("install_state_symlink_list");
    let home = root.join("home");
    fs::create_dir_all(&home).expect("temp root should be created");
    let canonical_root = fs::canonicalize(&root).expect("child cwd should canonicalize");
    let state = root.join("state.json");
    let output = run(
        &root,
        &[
            "setup-state-list-symlinks-under",
            &path_text(&state),
            "links",
        ],
    );
    assert_output(&output, 0, "", "");

    fs::write(&state, "{").expect("corrupt state should be written");
    let output = run(
        &root,
        &[
            "setup-state-list-symlinks-under",
            &path_text(&state),
            "links",
        ],
    );
    assert_output(&output, 0, "", "");

    write_json(&state, &json!({"version": 1, "files": []}));
    let output = run(
        &root,
        &[
            "setup-state-list-symlinks-under",
            &path_text(&state),
            "links",
        ],
    );
    assert_output(&output, 0, "", "");

    write_json(&state, &json!({"version": 4, "files": {}}));
    let output = run(
        &root,
        &[
            "setup-state-list-symlinks-under",
            &path_text(&state),
            "links",
        ],
    );
    assert_output(
        &output,
        0,
        "",
        "WARN: unsupported install-state version; skipping tracked symlink cleanup\n",
    );

    let absolute_dir = root.join("absolute-links");
    let absolute_child = absolute_dir.join("child");
    let outside = root.join("absolute-links-other/child");
    write_json(
        &state,
        &json!({
            "version": 1,
            "files": {
                path_text(&absolute_child): {"type": "symlink"},
                path_text(&absolute_dir): {"type": "symlink"},
                path_text(&outside): {"type": "symlink"},
                "links/child": {"type": "symlink"},
                "links/regular": {"type": "copy"},
                "other/child": {"type": "symlink"},
                "~/home-links/child": {"type": "symlink"}
            }
        }),
    );
    let output = run(
        &root,
        &[
            "setup-state-list-symlinks-under",
            &path_text(&state),
            &path_text(&absolute_dir),
        ],
    );
    assert_output(
        &output,
        0,
        &format!("{}\n{}\n", absolute_dir.display(), absolute_child.display()),
        "",
    );

    let output = run(
        &root,
        &[
            "setup-state-list-symlinks-under",
            &path_text(&state),
            "links",
        ],
    );
    assert_output(
        &output,
        0,
        &format!("{}\n", canonical_root.join("links/child").display()),
        "",
    );

    let output = run(
        &root,
        &[
            "setup-state-list-symlinks-under",
            &path_text(&state),
            "~/home-links",
        ],
    );
    assert_output(
        &output,
        0,
        &format!("{}\n", home.join("home-links/child").display()),
        "",
    );
    fs::remove_dir_all(root).expect("temp root should be removed");
}

#[test]
fn project_hook_cleanup_listing_handles_bad_state_and_filters_rows() {
    let root = unique_temp_dir("install_state_project_hooks");
    let home = root.join("home");
    fs::create_dir_all(&home).expect("temp root should be created");
    let state = root.join("state.json");
    let output = run(
        &root,
        &["setup-state-list-project-hooks", &path_text(&state)],
    );
    assert_output(&output, 0, "", "");

    fs::write(&state, "{").expect("corrupt state should be written");
    let output = run(
        &root,
        &["setup-state-list-project-hooks", &path_text(&state)],
    );
    assert_output(&output, 0, "", "");

    write_json(&state, &json!({"version": 1, "project_hooks": []}));
    let output = run(
        &root,
        &["setup-state-list-project-hooks", &path_text(&state)],
    );
    assert_output(&output, 0, "", "");

    write_json(&state, &json!({"version": 3, "project_hooks": {}}));
    let output = run(
        &root,
        &["setup-state-list-project-hooks", &path_text(&state)],
    );
    assert_output(
        &output,
        0,
        "",
        "WARN: unsupported install-state version; skipping project hook cleanup\n",
    );

    let absolute_hook = root.join("project/.git/hooks/pre-push");
    write_json(
        &state,
        &json!({
            "version": 1,
            "project_hooks": {
                "": {"repo_dir": "/ignored", "hook_name": "pre-commit"},
                "/missing-name": {"repo_dir": "/ignored"},
                path_text(&absolute_hook): {"repo_dir": path_text(&root.join("project")), "hook_name": "pre-push"},
                "~/project/.git/hooks/pre-commit": {"repo_dir": "~/project", "hook_name": "pre-commit"}
            }
        }),
    );
    let output = run(
        &root,
        &["setup-state-list-project-hooks", &path_text(&state)],
    );
    assert_output(
        &output,
        0,
        &format!(
            "{}\tpre-push\t{}\n{}\tpre-commit\t~/project\n",
            absolute_hook.display(),
            root.join("project").display(),
            home.join("project/.git/hooks/pre-commit").display()
        ),
        "",
    );
    fs::remove_dir_all(root).expect("temp root should be removed");
}
