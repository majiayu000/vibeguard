mod common;

use common::{assert_output, path_text, run_with_home as run, unique_temp_dir, write_json};
use serde_json::json;
use std::fs;

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
