use serde_json::{Value, json};
use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_REPO_ID: AtomicU64 = AtomicU64::new(0);

struct TestRepo {
    path: PathBuf,
}

impl TestRepo {
    fn new(label: &str) -> Self {
        let id = NEXT_REPO_ID.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "vibeguard-runtime-manifest-{label}-{}-{id}",
            std::process::id()
        ));
        fs::create_dir_all(path.join("schemas")).expect("temporary repo should be created");
        Self { path }
    }

    fn write_manifest(&self, value: &Value) {
        let text = serde_json::to_string(value).expect("test manifest should serialize");
        self.write_manifest_raw(&text);
    }

    fn write_manifest_raw(&self, text: &str) {
        fs::write(self.path.join("schemas/install-modules.json"), text)
            .expect("test manifest should be written");
    }

    fn write_rule(&self, relative_path: &str) {
        let path = self.path.join(relative_path);
        fs::create_dir_all(path.parent().expect("rule should have a parent directory"))
            .expect("rule parent should be created");
        fs::write(path, "# test rule\n").expect("test rule should be written");
    }

    fn cleanup(self) {
        fs::remove_dir_all(self.path).expect("temporary repo should be removed");
    }
}

fn run(repo: &TestRepo, command: &str, extra_args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"))
        .arg(command)
        .arg(&repo.path)
        .args(extra_args)
        .current_dir(&repo.path)
        .output()
        .expect("manifest CLI command should run")
}

fn stdout(output: &Output) -> String {
    String::from_utf8(output.stdout.clone()).expect("stdout should be UTF-8")
}

fn stderr(output: &Output) -> String {
    String::from_utf8(output.stderr.clone()).expect("stderr should be UTF-8")
}

fn assert_success(output: &Output, expected_stdout: &str) {
    assert_eq!(output.status.code(), Some(0), "stderr={}", stderr(output));
    assert_eq!(stdout(output), expected_stdout);
    assert_eq!(stderr(output), "");
}

fn assert_failure(output: &Output, expected_error: &str) {
    assert_eq!(output.status.code(), Some(1), "stdout={}", stdout(output));
    assert_eq!(stdout(output), "");
    let error = stderr(output);
    assert!(
        error.starts_with("vibeguard-runtime error: "),
        "unexpected stderr: {error}"
    );
    assert!(
        error.contains(expected_error),
        "stderr did not contain {expected_error:?}: {error}"
    );
}

fn one_module(module: Value) -> Value {
    json!({ "modules": [module] })
}

fn rule_module(paths: Value) -> Value {
    json!({
        "id": "bad-rule-module",
        "kind": "rules",
        "languages": [],
        "paths": paths
    })
}

#[test]
fn manifest_commands_emit_ordered_filtered_and_deduplicated_links() {
    let repo = TestRepo::new("success");
    for rule in [
        "rules/claude-rules/common/zeta.md",
        "rules/claude-rules/common/alpha.md",
        "rules/claude-rules/common/shared.md",
        "rules/claude-rules/rust/quality.md",
        "rules/claude-rules/golang/quality.md",
        "rules/claude-rules/python/quality.md",
    ] {
        repo.write_rule(rule);
    }
    repo.write_manifest(&json!({
        "modules": [
            {
                "id": "skills-codex",
                "kind": "skills",
                "target": "~/.codex/skills/",
                "paths": ["skills/zeta/", "workflows/alpha/"]
            },
            {
                "id": "skills-other-target",
                "kind": "skills",
                "target": "~/.claude/skills/",
                "paths": ["skills/not-selected/"]
            },
            {
                "id": "common-first",
                "kind": "rules",
                "paths": [
                    "rules/claude-rules/common/zeta.md",
                    "rules/claude-rules/common/alpha.md"
                ]
            },
            {
                "id": "common-second",
                "kind": "rules",
                "languages": [],
                "paths": ["rules/claude-rules/common/shared.md"]
            },
            {
                "id": "rust",
                "kind": "rules",
                "languages": ["rust", "RUST", ""],
                "paths": ["rules/claude-rules/rust/quality.md"]
            },
            {
                "id": "go",
                "kind": "rules",
                "languages": ["go"],
                "paths": ["rules/claude-rules/golang/quality.md"]
            },
            {
                "id": "python",
                "kind": "rules",
                "languages": ["python"],
                "paths": ["rules/claude-rules/python/quality.md"]
            }
        ]
    }));

    let skills = run(&repo, "setup-manifest-skill-links", &["~/.codex/skills/"]);
    assert_success(&skills, "skills/zeta\tzeta\nworkflows/alpha\talpha\n");

    let links = run(
        &repo,
        "setup-manifest-rule-links",
        &[" RUST, golang,rust, "],
    );
    assert_success(
        &links,
        concat!(
            "rules/claude-rules/common/zeta.md\tcommon/zeta.md\tcommon\n",
            "rules/claude-rules/common/alpha.md\tcommon/alpha.md\tcommon\n",
            "rules/claude-rules/common/shared.md\tcommon/shared.md\tcommon\n",
            "rules/claude-rules/rust/quality.md\trust/quality.md\trust\n",
            "rules/claude-rules/golang/quality.md\tgolang/quality.md\tgolang\n"
        ),
    );

    let labels = run(&repo, "setup-manifest-rule-labels", &["rust,golang"]);
    assert_success(&labels, "common\nrust\ngolang\n");
    repo.cleanup();
}

#[test]
fn missing_manifest_and_missing_cli_arguments_fail_visibly() {
    let repo = TestRepo::new("missing");
    for command in [
        "setup-manifest-skill-links",
        "setup-manifest-rule-links",
        "setup-manifest-rule-labels",
    ] {
        let extra_args: &[&str] = if command == "setup-manifest-skill-links" {
            &["~/.codex/skills/"]
        } else {
            &[]
        };
        let output = run(&repo, command, extra_args);
        assert_failure(&output, "vibeguard-runtime error:");
    }

    let missing_repo_argument = Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"))
        .arg("setup-manifest-rule-links")
        .output()
        .expect("manifest CLI command should run");
    assert_failure(
        &missing_repo_argument,
        "Usage: vibeguard-runtime setup-manifest-rule-links",
    );
    repo.cleanup();
}

#[test]
fn malformed_json_and_non_object_roots_fail_visibly() {
    let repo = TestRepo::new("parse-root");
    for (manifest, expected_error) in [
        ("{]", "line 1 column"),
        ("[]", "manifest root must be an object"),
        ("null", "manifest root must be an object"),
    ] {
        repo.write_manifest_raw(manifest);
        let output = run(&repo, "setup-manifest-rule-links", &[]);
        assert_failure(&output, expected_error);
    }
    repo.cleanup();
}

#[test]
fn invalid_modules_shapes_fail_visibly() {
    let repo = TestRepo::new("modules");
    for (manifest, expected_error) in [
        (json!({}), "manifest modules must be a list"),
        (
            json!({ "modules": { "kind": "rules" } }),
            "manifest modules must be a list",
        ),
        (
            json!({ "modules": [17] }),
            "manifest module entry is not an object",
        ),
    ] {
        repo.write_manifest(&manifest);
        let output = run(&repo, "setup-manifest-rule-links", &[]);
        assert_failure(&output, expected_error);
    }
    repo.write_manifest(&json!({"modules": [17]}));
    let skills = run(&repo, "setup-manifest-skill-links", &["~/.codex/skills/"]);
    assert_failure(&skills, "manifest module entry is not an object");
    repo.cleanup();
}

#[test]
fn invalid_skill_path_shapes_fail_visibly() {
    let repo = TestRepo::new("skill-paths");
    let cases = [
        (json!("skills/vibeguard/"), "paths must be a list"),
        (json!([7]), "non-string path entry"),
        (json!([""]), "skill path must be repo-relative"),
        (
            json!(["/skills/vibeguard"]),
            "skill path must be repo-relative",
        ),
        (
            json!(["skills\\vibeguard"]),
            "skill path must be repo-relative",
        ),
        (
            json!(["skills/../vibeguard"]),
            "skill path must not contain '..'",
        ),
        (json!(["."]), "skill path must name a skill directory"),
    ];
    for (paths, expected_error) in cases {
        repo.write_manifest(&one_module(json!({
            "id": "bad-skill-module",
            "kind": "skills",
            "target": "~/.codex/skills/",
            "paths": paths
        })));
        let output = run(&repo, "setup-manifest-skill-links", &["~/.codex/skills/"]);
        assert_failure(&output, expected_error);
    }
    repo.cleanup();
}

#[test]
fn invalid_language_shapes_fail_visibly() {
    let repo = TestRepo::new("languages");
    for (languages, expected_error) in [
        (json!("rust"), "languages must be a list"),
        (json!(["rust", 7]), "non-string language entry"),
    ] {
        repo.write_manifest(&one_module(json!({
            "id": "bad-languages",
            "kind": "rules",
            "languages": languages,
            "paths": []
        })));
        let output = run(&repo, "setup-manifest-rule-links", &["rust"]);
        assert_failure(&output, expected_error);
    }
    repo.cleanup();
}

#[test]
fn invalid_rule_path_shapes_and_missing_files_fail_visibly() {
    let repo = TestRepo::new("rule-paths");
    let cases = [
        (
            json!("rules/claude-rules/common/x.md"),
            "paths must be a list",
        ),
        (json!([7]), "non-string rule path"),
        (json!([""]), "rule path must be repo-relative"),
        (json!(["/rules/x.md"]), "rule path must be repo-relative"),
        (json!(["rules\\x.md"]), "rule path must be repo-relative"),
        (
            json!(["rules/claude-rules/../x.md"]),
            "rule path must not contain '..'",
        ),
        (json!(["rules/claude-rules/common/x.txt"]), "Markdown file"),
        (
            json!(["docs/rules/common/x.md"]),
            "must live under rules/claude-rules/",
        ),
        (
            json!(["rules/claude-rules//x.md"]),
            "must include a rule subdirectory",
        ),
        (
            json!(["rules/claude-rules/common/missing.md"]),
            "missing rule path rules/claude-rules/common/missing.md",
        ),
    ];
    for (paths, expected_error) in cases {
        repo.write_manifest(&one_module(rule_module(paths)));
        let output = run(&repo, "setup-manifest-rule-links", &[]);
        assert_failure(&output, expected_error);
    }
    repo.cleanup();
}

#[test]
fn irrelevant_modules_are_filtered_before_invalid_optional_fields() {
    let repo = TestRepo::new("filter-before-validate");
    repo.write_manifest(&json!({
        "modules": [
            {
                "id": "other-skill-target",
                "kind": "skills",
                "target": "~/.claude/skills/",
                "paths": "invalid-but-unselected"
            },
            {
                "id": "unrelated-kind",
                "kind": "hook",
                "languages": "invalid-but-unrelated",
                "paths": "invalid-but-unrelated"
            }
        ]
    }));

    let skills = run(&repo, "setup-manifest-skill-links", &["~/.codex/skills/"]);
    assert_success(&skills, "");
    let rules = run(&repo, "setup-manifest-rule-links", &["rust"]);
    assert_success(&rules, "");
    repo.cleanup();
}
