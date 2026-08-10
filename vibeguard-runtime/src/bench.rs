use serde_json::json;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::bench_support::{
    CaseResult, Decision, build_report, measured_case, path_str, post_write_decision,
    render_benchmark_human, require_success, run_runtime,
};

type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;

const USAGE: &str = "Usage: vibeguard-runtime bench [--json]";

struct Workspace {
    root: PathBuf,
}

impl Workspace {
    fn create() -> Result<Self> {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("vibeguard-bench-{}-{nonce}", std::process::id()));
        fs::create_dir(&root)?;
        fs::create_dir(root.join("home"))?;
        fs::create_dir(root.join("tmp"))?;
        Ok(Self { root })
    }

    fn cleanup(mut self) -> Result {
        fs::remove_dir_all(&self.root)?;
        self.root.clear();
        Ok(())
    }
}

impl Drop for Workspace {
    fn drop(&mut self) {
        if self.root.as_os_str().is_empty() {
            return;
        }
        if let Err(error) = fs::remove_dir_all(&self.root) {
            eprintln!(
                "vibeguard-runtime bench cleanup failed for {}: {error}",
                self.root.display()
            );
        }
    }
}

pub fn run(args: &[String]) -> Result {
    let json_output = match args {
        [] => false,
        [flag] if flag == "--json" => true,
        _ => return Err(USAGE.into()),
    };

    let workspace = Workspace::create()?;
    let runtime = std::env::current_exe()?;
    let cases = run_cases(&workspace.root, &runtime)?;
    let report = build_report(&cases);
    workspace.cleanup()?;

    if json_output {
        println!("{}", serde_json::to_string(&report)?);
    } else {
        render_benchmark_human(&report)?;
    }
    Ok(())
}

fn run_cases(root: &Path, runtime: &Path) -> Result<Vec<CaseResult>> {
    let mut cases = Vec::with_capacity(10);
    cases.extend(hallucinated_edit_target_cases(root, runtime)?);
    cases.extend(duplicate_definition_cases(root, runtime)?);
    cases.extend(swallowed_exception_cases(root, runtime)?);
    cases.extend(dangerous_shell_cases(root, runtime)?);
    cases.extend(unverified_done_cases(root, runtime)?);
    Ok(cases)
}

fn reset_file(path: &Path) -> Result {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn reset_dir(path: &Path) -> Result {
    match fs::remove_dir_all(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn hallucinated_edit_target_cases(root: &Path, runtime: &Path) -> Result<Vec<CaseResult>> {
    let project = root.join("hallucinated-edit-target");
    fs::create_dir_all(project.join("src"))?;
    let existing = project.join("src/service.rs");
    fs::write(&existing, "pub fn existing_api() {}\n")?;
    let missing = project.join("src/invented_api.rs");
    let log = project.join("events.jsonl");

    let positive_input = json!({"tool_input": {
        "file_path": missing,
        "old_string": "pub fn invented_api() {}",
        "new_string": "pub fn invented_api() { todo!() }"
    }})
    .to_string();
    let negative_input = json!({"tool_input": {
        "file_path": existing,
        "old_string": "pub fn existing_api() {}",
        "new_string": "pub fn existing_api() { }"
    }})
    .to_string();

    Ok(vec![
        measured_case(
            "hallucinated_edit_target",
            true,
            || {
                reset_file(&log)?;
                reset_file(&missing)?;
                fs::write(&existing, "pub fn existing_api() {}\n")?;
                Ok(())
            },
            || {
                let output = run_runtime(
                    runtime,
                    &["pre-edit-check", "800", "400", path_str(&log)?],
                    &positive_input,
                    root,
                )?;
                require_success(&output, "pre-edit positive")?;
                Ok(
                    if String::from_utf8_lossy(&output.stdout).contains("\"decision\": \"block\"") {
                        Decision::Block
                    } else {
                        Decision::Allow
                    },
                )
            },
        )?,
        measured_case(
            "hallucinated_edit_target",
            false,
            || {
                reset_file(&log)?;
                reset_file(&missing)?;
                fs::write(&existing, "pub fn existing_api() {}\n")?;
                Ok(())
            },
            || {
                let output = run_runtime(
                    runtime,
                    &["pre-edit-check", "800", "400", path_str(&log)?],
                    &negative_input,
                    root,
                )?;
                require_success(&output, "pre-edit negative")?;
                Ok(
                    if String::from_utf8_lossy(&output.stdout).contains("\"decision\": \"block\"") {
                        Decision::Block
                    } else {
                        Decision::Allow
                    },
                )
            },
        )?,
    ])
}

fn duplicate_definition_cases(root: &Path, runtime: &Path) -> Result<Vec<CaseResult>> {
    let project = root.join("duplicate-definition");
    fs::create_dir_all(project.join(".git"))?;
    fs::create_dir_all(project.join("src"))?;
    fs::write(
        project.join("src/existing.rs"),
        "pub fn load_account() {}\n",
    )?;
    let target = project.join("src/new_service.rs");
    let log = project.join("events.jsonl");

    let run = |content: &str| -> Result<Decision> {
        let input = json!({"tool_input": {
            "file_path": target,
            "content": content
        }})
        .to_string();
        let output = run_runtime(
            runtime,
            &[
                "post-write-check",
                "800",
                "400",
                "100",
                "100",
                "10",
                path_str(&log)?,
            ],
            &input,
            root,
        )?;
        post_write_decision(&output)
    };

    Ok(vec![
        measured_case(
            "duplicate_definition",
            true,
            || {
                reset_file(&log)?;
                reset_file(&target)
            },
            || run("pub fn load_account() {}\n"),
        )?,
        measured_case(
            "duplicate_definition",
            false,
            || {
                reset_file(&log)?;
                reset_file(&target)
            },
            || run("pub fn save_account() {}\n"),
        )?,
    ])
}

fn swallowed_exception_cases(root: &Path, runtime: &Path) -> Result<Vec<CaseResult>> {
    let project = root.join("swallowed-exception");
    fs::create_dir_all(project.join(".git"))?;
    fs::create_dir_all(project.join("src"))?;
    let source = project.join("service.js");
    let log = project.join("events.jsonl");

    let run = |content: &str| -> Result<Decision> {
        let input = json!({"tool_input": {
            "file_path": source,
            "content": content
        }})
        .to_string();
        let output = run_runtime(
            runtime,
            &[
                "post-write-check",
                "800",
                "400",
                "100",
                "100",
                "10",
                path_str(&log)?,
            ],
            &input,
            root,
        )?;
        post_write_decision(&output)
    };

    Ok(vec![
        measured_case(
            "swallowed_exception",
            true,
            || {
                reset_file(&log)?;
                reset_file(&source)
            },
            || run("try { run(); } catch (error) { }\n"),
        )?,
        measured_case(
            "swallowed_exception",
            false,
            || {
                reset_file(&log)?;
                reset_file(&source)
            },
            || run("try { run(); } catch (error) { report(error); }\n"),
        )?,
    ])
}

fn dangerous_shell_cases(root: &Path, runtime: &Path) -> Result<Vec<CaseResult>> {
    let run = |command: &str| -> Result<Decision> {
        let input = json!({"tool_input": {"command": command}}).to_string();
        let output = run_runtime(runtime, &["pre-bash-check", path_str(root)?], &input, root)?;
        require_success(&output, "pre-bash benchmark")?;
        Ok(
            if String::from_utf8_lossy(&output.stdout).starts_with("BLOCK\n") {
                Decision::Block
            } else {
                Decision::Allow
            },
        )
    };
    Ok(vec![
        measured_case(
            "dangerous_shell_or_git",
            true,
            || reset_dir(&root.join("logs")),
            || run("git restore ."),
        )?,
        measured_case(
            "dangerous_shell_or_git",
            false,
            || reset_dir(&root.join("logs")),
            || run("git restore -- src/lib.rs"),
        )?,
    ])
}

fn unverified_done_cases(root: &Path, runtime: &Path) -> Result<Vec<CaseResult>> {
    let project = root.join("unverified-done");
    fs::create_dir_all(project.join(".git"))?;
    fs::create_dir_all(project.join("src"))?;
    fs::write(
        project.join("Cargo.toml"),
        "[package]\nname = \"bench-stop\"\nversion = \"0.0.0\"\n",
    )?;
    let log = project
        .join("logs/projects/bench-project")
        .join("events.jsonl");
    fs::create_dir_all(log.parent().ok_or("benchmark log has no parent")?)?;
    let source = project.join("src/lib.rs");

    let seed = |verified: bool| -> Result {
        let mut events = vec![json!({
            "session": "bench-session",
            "hook": "pre-edit-guard",
            "tool": "Edit",
            "decision": "pass",
            "detail": source
        })];
        if verified {
            events.push(json!({
                "session": "bench-session",
                "hook": "pre-bash-guard",
                "tool": "Bash",
                "decision": "pass",
                "detail": "cargo test --manifest-path Cargo.toml"
            }));
        }
        let fixture = events
            .iter()
            .map(serde_json::to_string)
            .collect::<std::result::Result<Vec<_>, _>>()?
            .join("\n");
        fs::write(&log, format!("{fixture}\n"))?;
        Ok(())
    };
    let run = || -> Result<Decision> {
        let output = run_runtime(
            runtime,
            &["hook", "stop"],
            r#"{"hook_event_name":"Stop"}"#,
            &project,
        )?;
        require_success(&output, "Stop benchmark")?;
        Ok(if output.stdout.is_empty() {
            Decision::Allow
        } else {
            Decision::Warn
        })
    };

    Ok(vec![
        measured_case("unverified_done_claim", true, || seed(false), run)?,
        measured_case("unverified_done_claim", false, || seed(true), run)?,
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleanup_failure_is_returned_before_metrics_can_be_published() {
        let workspace = Workspace::create().expect("workspace");
        fs::remove_dir_all(&workspace.root).expect("remove workspace directory");
        fs::write(&workspace.root, "not a directory").expect("replace workspace with file");
        let path = workspace.root.clone();
        assert!(workspace.cleanup().is_err());
        fs::remove_file(path).expect("remove cleanup fixture");
    }
}
