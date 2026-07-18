use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_ID: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new(label: &str) -> Self {
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "vibeguard-setup-markdown-{label}-{}-{id}",
            std::process::id()
        ));
        fs::create_dir_all(&root).expect("fixture root should be created");
        Self { root }
    }

    fn path(&self, name: &str) -> PathBuf {
        self.root.join(name)
    }

    fn write(&self, name: &str, text: &str) -> PathBuf {
        let path = self.path(name);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("fixture parent should be created");
        }
        fs::write(&path, text).expect("fixture file should be written");
        path
    }

    fn cleanup(self) {
        fs::remove_dir_all(self.root).expect("fixture root should be removed");
    }
}

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"))
}

fn run(fixture: &Fixture, command: &str, args: &[&Path], tail: &[&str]) -> Output {
    bin()
        .arg(command)
        .args(args)
        .args(tail)
        .current_dir(&fixture.root)
        .output()
        .expect("setup Markdown command should run")
}

fn output_text(bytes: &[u8]) -> String {
    String::from_utf8(bytes.to_vec()).expect("command output should be UTF-8")
}

fn assert_success(output: &Output, expected_stdout: &str) {
    assert_eq!(
        output.status.code(),
        Some(0),
        "stderr={}",
        output_text(&output.stderr)
    );
    assert_eq!(output_text(&output.stdout), expected_stdout);
    assert_eq!(output_text(&output.stderr), "");
}

fn assert_visible_failure(output: &Output, stable_message: Option<&str>) {
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(output_text(&output.stdout), "");
    let error = output_text(&output.stderr);
    assert!(
        error.starts_with("vibeguard-runtime error: "),
        "unexpected stderr: {error}"
    );
    if let Some(message) = stable_message {
        assert!(error.contains(message), "stderr={error}");
    }
}

const RULES: &str = concat!(
    "<!-- vibeguard-start -->\n",
    "Repo: __VIBEGUARD_DIR__\n",
    "Rules: __VIBEGUARD_RULE_COUNT__\n",
    "<!-- vibeguard-end -->\n"
);

#[test]
fn markdown_argument_and_missing_rules_errors_are_visible() {
    let fixture = Fixture::new("errors");

    for command in ["setup-md-diff-inject", "setup-md-inject", "setup-md-remove"] {
        let output = bin()
            .arg(command)
            .current_dir(&fixture.root)
            .output()
            .expect("setup Markdown command should run");
        assert_visible_failure(&output, Some("Usage: vibeguard-runtime setup-md-"));
    }

    let target = fixture.path("AGENTS.md");
    let missing_rules = fixture.path("missing-rules.md");
    let missing = run(
        &fixture,
        "setup-md-inject",
        &[&target, &missing_rules],
        &["/repo", "12"],
    );
    assert_visible_failure(&missing, None);
    assert!(!target.exists());

    let rules = fixture.write("rules.md", RULES);
    let invalid_count = run(
        &fixture,
        "setup-md-diff-inject",
        &[&target, &rules],
        &["/repo", "twelve"],
    );
    assert_visible_failure(&invalid_count, Some("Invalid rule count: twelve"));
    assert!(!target.exists());
    fixture.cleanup();
}

#[test]
fn diff_is_non_mutating_and_inject_is_exact_and_idempotent() {
    let fixture = Fixture::new("inject");
    let target = fixture.write("AGENTS.md", "Intro\n");
    let rules = fixture.write("rules.md", RULES);
    let rendered_rules = concat!(
        "<!-- vibeguard-start -->\n",
        "Repo: /workspace/repo\n",
        "Rules: 126\n",
        "<!-- vibeguard-end -->"
    );
    let managed_only = format!("{rendered_rules}\n");
    let expected_content = format!("Intro\n\n{rendered_rules}\n");

    let missing_target = fixture.path("missing-target.md");
    assert_success(
        &run(
            &fixture,
            "setup-md-inject",
            &[&missing_target, &rules],
            &["/workspace/repo", "126"],
        ),
        "APPENDED\n",
    );
    assert_eq!(fs::read_to_string(&missing_target).unwrap(), managed_only);

    let empty_target = fixture.write("empty-target.md", "");
    assert_success(
        &run(
            &fixture,
            "setup-md-inject",
            &[&empty_target, &rules],
            &["/workspace/repo", "126"],
        ),
        "APPENDED\n",
    );
    assert_eq!(fs::read_to_string(&empty_target).unwrap(), managed_only);

    let diff = run(
        &fixture,
        "setup-md-diff-inject",
        &[&target, &rules],
        &["/workspace/repo", "126"],
    );
    let expected_diff = format!(
        "--- {0}\n+++ {0}\n@@\n-Intro\n+Intro\n+\n+<!-- vibeguard-start -->\n+Repo: /workspace/repo\n+Rules: 126\n+<!-- vibeguard-end -->\nAPPENDED\n",
        target.display()
    );
    assert_success(&diff, &expected_diff);
    assert_eq!(fs::read_to_string(&target).unwrap(), "Intro\n");

    let inject = run(
        &fixture,
        "setup-md-inject",
        &[&target, &rules],
        &["/workspace/repo", "126"],
    );
    assert_success(&inject, "APPENDED\n");
    assert_eq!(fs::read_to_string(&target).unwrap(), expected_content);

    let skip_diff = run(
        &fixture,
        "setup-md-diff-inject",
        &[&target, &rules],
        &["/workspace/repo", "126"],
    );
    assert_success(&skip_diff, "SKIP\n");
    let before_repeat = fs::read(&target).unwrap();
    let repeat = run(
        &fixture,
        "setup-md-inject",
        &[&target, &rules],
        &["/workspace/repo", "126"],
    );
    assert_success(&repeat, "UPDATED\n");
    assert_eq!(fs::read(&target).unwrap(), before_repeat);
    fixture.cleanup();
}

#[test]
fn inject_updates_only_the_managed_block() {
    let fixture = Fixture::new("update");
    let target = fixture.write(
        "CLAUDE.md",
        concat!(
            "Before\n\n",
            "<!-- vibeguard-start -->\nold\n<!-- vibeguard-end -->\n\n",
            "After\n"
        ),
    );
    let rules = fixture.write("rules.md", RULES);

    let output = run(
        &fixture,
        "setup-md-inject",
        &[&target, &rules],
        &["/new/repo", "80"],
    );
    assert_success(&output, "UPDATED\n");
    assert_eq!(
        fs::read_to_string(&target).unwrap(),
        concat!(
            "Before\n\n",
            "<!-- vibeguard-start -->\n",
            "Repo: /new/repo\n",
            "Rules: 80\n",
            "<!-- vibeguard-end -->\n\n",
            "After\n"
        )
    );
    fixture.cleanup();
}

#[test]
fn remove_distinguishes_missing_plain_managed_and_mixed_files() {
    let fixture = Fixture::new("remove");
    let missing = fixture.path("missing.md");
    assert_success(
        &run(&fixture, "setup-md-remove", &[&missing], &[]),
        "NOT_FOUND\n",
    );

    let plain = fixture.write("plain.md", "Unmanaged text\n");
    assert_success(
        &run(&fixture, "setup-md-remove", &[&plain], &[]),
        "NOT_FOUND\n",
    );
    assert_eq!(fs::read_to_string(&plain).unwrap(), "Unmanaged text\n");

    let managed = fixture.write(
        "managed.md",
        "<!-- vibeguard-start -->\nmanaged\n<!-- vibeguard-end -->\n",
    );
    assert_success(
        &run(&fixture, "setup-md-remove", &[&managed], &[]),
        "REMOVED\n",
    );
    assert_eq!(fs::read_to_string(&managed).unwrap(), "\n");

    let mixed = fixture.write(
        "mixed.md",
        "Before\n\n<!-- vibeguard-start -->\nmanaged\n<!-- vibeguard-end -->\n\nAfter\n",
    );
    assert_success(
        &run(&fixture, "setup-md-remove", &[&mixed], &[]),
        "REMOVED\n",
    );
    assert_eq!(fs::read_to_string(&mixed).unwrap(), "Before\n\nAfter\n");
    fixture.cleanup();
}

#[test]
fn markdown_read_and_write_errors_are_visible_without_success_output() {
    let fixture = Fixture::new("io-errors");
    let rules = fixture.write("rules.md", RULES);
    let blocking_parent = fixture.write("not-a-directory", "blocking file\n");
    let target = blocking_parent.join("AGENTS.md");
    let write_error = run(
        &fixture,
        "setup-md-inject",
        &[&target, &rules],
        &["/repo", "1"],
    );
    assert_visible_failure(&write_error, None);

    let directory = fixture.path("directory-target");
    fs::create_dir_all(&directory).unwrap();
    let directory_write_error = run(
        &fixture,
        "setup-md-inject",
        &[&directory, &rules],
        &["/repo", "1"],
    );
    assert_visible_failure(&directory_write_error, None);
    let read_error = run(&fixture, "setup-md-remove", &[&directory], &[]);
    assert_visible_failure(&read_error, None);
    fixture.cleanup();
}
