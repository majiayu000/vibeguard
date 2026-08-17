mod common;

use common::{bin, unique_temp_dir};
use serde_json::{Value, json};
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};
use std::{env, fs};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

fn run_with_stdin(command: &mut Command, input: &str) -> Output {
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn gemini_payload(tool_name: &str, tool_input: Value) -> String {
    json!({
        "session_id": "gemini-session-test",
        "cwd": "/repo",
        "hook_event_name": "BeforeTool",
        "tool_name": tool_name,
        "tool_input": tool_input
    })
    .to_string()
}

fn run_wrapper(project: &Path, home: &Path, log_root: &Path, input: &str) -> Output {
    let source_root = repo_root();
    let test_bin = home.join("test-bin");
    fs::create_dir_all(home.join(".vibeguard")).unwrap();
    fs::create_dir_all(&test_bin).unwrap();
    let pnpm = test_bin.join("pnpm");
    fs::write(&pnpm, "#!/bin/sh\nexit 0\n").unwrap();
    #[cfg(unix)]
    fs::set_permissions(&pnpm, fs::Permissions::from_mode(0o700)).unwrap();
    let wrapper = home.join(".vibeguard/run-hook-gemini.sh");
    fs::copy(source_root.join("hooks/run-hook-gemini.sh"), &wrapper).unwrap();
    fs::write(
        home.join(".vibeguard/repo-path"),
        source_root.to_string_lossy().as_bytes(),
    )
    .unwrap();
    let runtime = bin().get_program().to_owned();
    let path = env::join_paths(
        std::iter::once(test_bin).chain(
            env::var_os("PATH")
                .into_iter()
                .flat_map(|value| env::split_paths(&value).collect::<Vec<_>>()),
        ),
    )
    .unwrap();
    let mut command = Command::new("bash");
    command
        .arg(wrapper)
        .args([
            "--test-only",
            runtime.to_str().unwrap(),
            source_root.join("hooks/run-hook.sh").to_str().unwrap(),
            source_root.join("hooks/_lib/timeout.sh").to_str().unwrap(),
            "dev-linked-repo",
            "8",
        ])
        .current_dir(project)
        .env_clear()
        .env("HOME", home)
        .env("PATH", path)
        .env("VIBEGUARD_RUNTIME", &runtime)
        .env("VIBEGUARD_LOG_DIR", log_root);
    if let Some(profile_file) = env::var_os("LLVM_PROFILE_FILE") {
        command.env("LLVM_PROFILE_FILE", profile_file);
    }
    run_with_stdin(&mut command, input)
}

fn first_project_event(log_root: &Path) -> Value {
    let project_dir = fs::read_dir(log_root.join("projects"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let text = fs::read_to_string(project_dir.join("events.jsonl")).unwrap();
    serde_json::from_str(text.lines().next().unwrap()).unwrap()
}

#[test]
fn gemini_wrapper_blocks_dangerous_shell_and_allows_safe_shell() {
    let root = unique_temp_dir("gemini-wrapper-shell");
    let project = root.join("project");
    let home = root.join("home");
    let log_root = root.join("logs");
    fs::create_dir_all(project.join(".git")).unwrap();

    let blocked = run_wrapper(
        &project,
        &home,
        &log_root,
        &gemini_payload("run_shell_command", json!({"command": "git restore ."})),
    );
    assert!(blocked.status.success(), "{:?}", blocked.status);
    let blocked_json: Value = serde_json::from_slice(&blocked.stdout).unwrap();
    assert_eq!(
        blocked_json["decision"],
        "deny",
        "stdout={} stderr={}",
        String::from_utf8_lossy(&blocked.stdout),
        String::from_utf8_lossy(&blocked.stderr)
    );
    assert!(
        blocked_json["reason"]
            .as_str()
            .unwrap()
            .contains("VIBEGUARD"),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&blocked.stdout),
        String::from_utf8_lossy(&blocked.stderr)
    );

    let event = first_project_event(&log_root);
    assert_eq!(event["hook"], "pre-bash-guard");
    assert_eq!(event["decision"], "block");
    assert_eq!(event["cli"], "gemini");
    assert_eq!(event["client"], "gemini");
    assert_eq!(event["client_variant"], "gemini-cli-hooks");
    assert_eq!(event["session"], "gemini-session-test");

    let safe = run_wrapper(
        &project,
        &home,
        &log_root,
        &gemini_payload("run_shell_command", json!({"command": "git status"})),
    );
    assert!(safe.status.success(), "{:?}", safe.status);
    assert_eq!(safe.stdout, b"{}\n");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn gemini_wrapper_preserves_advisories_corrections_and_denies_timeouts() {
    let root = unique_temp_dir("gemini-wrapper-output");
    let project = root.join("project");
    let home = root.join("home");
    let log_root = root.join("logs");
    fs::create_dir_all(project.join(".git")).unwrap();

    let correction = run_wrapper(
        &project,
        &home,
        &log_root,
        &gemini_payload(
            "run_shell_command",
            json!({"command": "npm install lodash"}),
        ),
    );
    let correction_json: Value = serde_json::from_slice(&correction.stdout).unwrap();
    assert_eq!(
        correction_json["decision"],
        "allow",
        "stdout={} stderr={}",
        String::from_utf8_lossy(&correction.stdout),
        String::from_utf8_lossy(&correction.stderr)
    );
    assert_eq!(
        correction_json["hookSpecificOutput"]["tool_input"]["command"],
        "pnpm add lodash"
    );

    let advisory = run_wrapper(
        &project,
        &home,
        &log_root,
        &gemini_payload(
            "write_file",
            json!({"file_path": project.join("new_module.rs"), "content": "fn main() {}"}),
        ),
    );
    let advisory_json: Value = serde_json::from_slice(&advisory.stdout).unwrap();
    assert!(
        advisory_json["systemMessage"]
            .as_str()
            .unwrap()
            .contains("search for similar implementation")
    );

    let source_root = repo_root();
    let timeout_home = root.join("timeout-home");
    let timeout_wrapper = timeout_home.join(".vibeguard/run-hook-gemini.sh");
    let slow_hook = root.join("slow-run-hook.sh");
    fs::create_dir_all(timeout_wrapper.parent().unwrap()).unwrap();
    fs::copy(
        source_root.join("hooks/run-hook-gemini.sh"),
        &timeout_wrapper,
    )
    .unwrap();
    fs::write(&slow_hook, "sleep 2\nprintf '{}\\n'\n").unwrap();
    let mut timeout_command = Command::new("bash");
    timeout_command
        .arg(timeout_wrapper)
        .args([
            "--test-only",
            bin().get_program().to_str().unwrap(),
            slow_hook.to_str().unwrap(),
            source_root.join("hooks/_lib/timeout.sh").to_str().unwrap(),
            "installed-snapshot",
            "0.1",
        ])
        .env("HOME", &timeout_home);
    let started = Instant::now();
    let timed_out = run_with_stdin(
        &mut timeout_command,
        &gemini_payload("run_shell_command", json!({"command": "git status"})),
    );
    assert!(started.elapsed() < Duration::from_secs(2));
    let timeout_json: Value = serde_json::from_slice(&timed_out.stdout).unwrap();
    assert_eq!(timeout_json["decision"], "deny");
    assert!(
        timeout_json["reason"]
            .as_str()
            .unwrap()
            .contains("could not execute the policy hook")
    );

    let stalled_home = root.join("stalled-home");
    let stalled_wrapper = stalled_home.join(".vibeguard/run-hook-gemini.sh");
    fs::create_dir_all(stalled_wrapper.parent().unwrap()).unwrap();
    fs::copy(
        source_root.join("hooks/run-hook-gemini.sh"),
        &stalled_wrapper,
    )
    .unwrap();
    let mut stalled_command = Command::new("bash");
    stalled_command
        .arg(stalled_wrapper)
        .args([
            "--test-only",
            bin().get_program().to_str().unwrap(),
            slow_hook.to_str().unwrap(),
            source_root.join("hooks/_lib/timeout.sh").to_str().unwrap(),
            "installed-snapshot",
            "0.1",
        ])
        .env("HOME", &stalled_home)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut stalled_child = stalled_command.spawn().unwrap();
    let mut held_stdin = stalled_child.stdin.take().unwrap();
    held_stdin.write_all(b"{").unwrap();
    let stalled_started = Instant::now();
    let stalled = stalled_child.wait_with_output().unwrap();
    drop(held_stdin);
    assert!(stalled_started.elapsed() < Duration::from_secs(4));
    let stalled_json: Value = serde_json::from_slice(&stalled.stdout).unwrap();
    assert_eq!(stalled_json["decision"], "deny");
    assert!(
        stalled_json["reason"]
            .as_str()
            .unwrap()
            .contains("could not read the BeforeTool payload")
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn gemini_wrapper_blocks_missing_replace_target_and_unknown_tools() {
    let root = unique_temp_dir("gemini-wrapper-edit");
    let project = root.join("project");
    let home = root.join("home");
    let log_root = root.join("logs");
    fs::create_dir_all(project.join(".git")).unwrap();
    fs::create_dir_all(project.join("src")).unwrap();
    let missing = project.join("src/missing.rs");

    let edit = run_wrapper(
        &project,
        &home,
        &log_root,
        &gemini_payload(
            "replace",
            json!({
                "file_path": missing,
                "old_string": "old",
                "new_string": "new"
            }),
        ),
    );
    let edit_json: Value = serde_json::from_slice(&edit.stdout).unwrap();
    assert_eq!(edit_json["decision"], "deny");

    let unknown = run_wrapper(
        &project,
        &home,
        &log_root,
        &gemini_payload("read_file", json!({"file_path": "README.md"})),
    );
    let unknown_json: Value = serde_json::from_slice(&unknown.stdout).unwrap();
    assert_eq!(unknown_json["decision"], "deny");
    assert!(
        unknown_json["reason"]
            .as_str()
            .unwrap()
            .contains("malformed or unsupported")
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn gemini_settings_lifecycle_is_idempotent_and_preserves_custom_hooks() {
    let root = unique_temp_dir("gemini-settings");
    let settings = root.join("settings.json");
    let wrapper = root.join("wrapper with spaces.sh");
    fs::create_dir_all(&root).unwrap();
    fs::write(
        &settings,
        serde_json::to_vec_pretty(&json!({
            "theme": "custom",
            "hooks": {
                "BeforeTool": [{
                    "matcher": "read_file",
                    "hooks": [{"name": "custom", "type": "command", "command": "custom-hook"}]
                }],
                "AfterTool": []
            }
        }))
        .unwrap(),
    )
    .unwrap();
    #[cfg(unix)]
    fs::set_permissions(&settings, fs::Permissions::from_mode(0o600)).unwrap();

    let first = bin()
        .args([
            "setup-gemini-hooks-upsert",
            settings.to_str().unwrap(),
            wrapper.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        first.status.success(),
        "{}",
        String::from_utf8_lossy(&first.stderr)
    );
    assert_eq!(first.stdout, b"CHANGED\n");
    let data: Value = serde_json::from_slice(&fs::read(&settings).unwrap()).unwrap();
    assert_eq!(data["theme"], "custom");
    assert_eq!(data["hooks"]["BeforeTool"].as_array().unwrap().len(), 2);
    assert!(data.to_string().contains("custom-hook"));
    assert!(data.to_string().contains("vibeguard-before-tool"));
    assert_eq!(
        data["hooks"]["BeforeTool"][1]["matcher"],
        "^(run_shell_command|write_file|replace)$"
    );
    assert_eq!(
        data["hooks"]["BeforeTool"][1]["hooks"][0]["timeout"],
        20_000
    );
    assert!(
        data["hooks"]["BeforeTool"][1]["hooks"][0]["command"]
            .as_str()
            .unwrap()
            .starts_with("/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash ")
    );
    #[cfg(unix)]
    assert_eq!(
        fs::metadata(&settings).unwrap().permissions().mode() & 0o777,
        0o600
    );

    let second = bin()
        .args([
            "setup-gemini-hooks-upsert",
            settings.to_str().unwrap(),
            wrapper.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert_eq!(second.stdout, b"SKIP\n");
    assert!(
        bin()
            .args([
                "setup-gemini-hooks-check",
                settings.to_str().unwrap(),
                wrapper.to_str().unwrap(),
            ])
            .status()
            .unwrap()
            .success()
    );

    let mut disabled = data.clone();
    disabled["hooksConfig"] = json!({"enabled": false});
    fs::write(&settings, serde_json::to_vec_pretty(&disabled).unwrap()).unwrap();
    assert!(
        !bin()
            .args([
                "setup-gemini-hooks-check",
                settings.to_str().unwrap(),
                wrapper.to_str().unwrap(),
            ])
            .status()
            .unwrap()
            .success()
    );

    let removed = bin()
        .args(["setup-gemini-hooks-remove", settings.to_str().unwrap()])
        .output()
        .unwrap();
    assert_eq!(removed.stdout, b"CHANGED\n");
    let data: Value = serde_json::from_slice(&fs::read(&settings).unwrap()).unwrap();
    assert_eq!(data["theme"], "custom");
    assert!(data.to_string().contains("custom-hook"));
    assert!(!data.to_string().contains("vibeguard-before-tool"));
    assert_eq!(data["hooks"]["AfterTool"], json!([]));

    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn gemini_settings_new_files_are_private_and_symlinks_fail_closed() {
    use std::os::unix::fs::symlink;

    let root = unique_temp_dir("gemini-settings-permissions");
    let fresh = root.join("fresh/settings.json");
    let wrapper = root.join("wrapper.sh");
    let created = bin()
        .args([
            "setup-gemini-hooks-upsert",
            fresh.to_str().unwrap(),
            wrapper.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(created.status.success());
    assert_eq!(
        fs::metadata(&fresh).unwrap().permissions().mode() & 0o777,
        0o600
    );

    let external = root.join("external.json");
    let linked = root.join("linked.json");
    fs::write(&external, "{}\n").unwrap();
    symlink(&external, &linked).unwrap();
    let rejected = bin()
        .args([
            "setup-gemini-hooks-upsert",
            linked.to_str().unwrap(),
            wrapper.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(!rejected.status.success());
    assert_eq!(fs::read_to_string(&external).unwrap(), "{}\n");
    assert!(linked.is_symlink());

    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn gemini_installed_wrapper_ignores_hostile_runtime_environment() {
    use std::os::unix::fs::{PermissionsExt, symlink};

    let root = unique_temp_dir("gemini-hostile-environment");
    let home = root.join("home");
    let project = root.join("project");
    let vibeguard_home = home.join(".vibeguard");
    let installed = vibeguard_home.join("installed");
    let source_root = repo_root();
    fs::create_dir_all(installed.join("bin")).unwrap();
    fs::create_dir_all(&project).unwrap();
    fs::copy(
        source_root.join("hooks/run-hook-gemini.sh"),
        vibeguard_home.join("run-hook-gemini.sh"),
    )
    .unwrap();
    fs::copy(
        source_root.join("hooks/run-hook.sh"),
        vibeguard_home.join("run-hook.sh"),
    )
    .unwrap();
    symlink(source_root.join("hooks"), installed.join("hooks")).unwrap();
    symlink(bin().get_program(), installed.join("bin/vibeguard-runtime")).unwrap();

    let marker = root.join("hostile-runtime-used");
    let hostile_runtime = root.join("hostile-runtime.sh");
    fs::write(
        &hostile_runtime,
        format!(
            "#!/bin/bash\nprintf used > '{}'\nprintf '{{}}\\n'\n",
            marker.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&hostile_runtime, fs::Permissions::from_mode(0o700)).unwrap();
    let hostile_config = root.join("hostile-config.json");
    fs::write(&hostile_config, r#"{"write_mode":"#).unwrap();

    let mut command = Command::new("/bin/bash");
    command
        .arg(vibeguard_home.join("run-hook-gemini.sh"))
        .current_dir(&project)
        .env("HOME", root.join("attacker-home"))
        .env("VIBEGUARD_RUNTIME", &hostile_runtime)
        .env("VIBEGUARD_POLICY_RUNTIME", &hostile_runtime)
        .env("VG_INTERNAL_CONFIG_FILE", &hostile_config)
        .env("VG_INTERNAL_POLICY_CWD", root.join("attacker-project"))
        .env("VIBEGUARD_EXECUTION_MODE", "dev-linked-repo")
        .env("VIBEGUARD_LOG_DIR", root.join("attacker-config"));
    let output = run_with_stdin(
        &mut command,
        &gemini_payload("run_shell_command", json!({"command": "git restore ."})),
    );
    assert!(output.status.success());
    let decision: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(decision["decision"], "deny");
    assert!(
        !decision["reason"]
            .as_str()
            .unwrap_or("")
            .contains("runtime config invalid")
    );
    assert!(!marker.exists());

    fs::remove_dir_all(root).unwrap();
}
