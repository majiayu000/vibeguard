use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

const BIN: &str = env!("CARGO_BIN_EXE_vibeguard-runtime");
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "vibeguard-v2-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.0) {
            if std::thread::panicking() {
                eprintln!("test cleanup failed: {error}");
            } else {
                panic!("test cleanup failed: {error}");
            }
        }
    }
}
fn invoke(args: &[&str], input: &str, cwd: Option<&Path>) -> Output {
    let mut command = Command::new(BIN);
    command
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(cwd) = cwd {
        command.current_dir(cwd);
    }
    let mut child = command.spawn().unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}
fn success(output: &Output) {
    assert!(
        output.status.success(),
        "stdout={}\nstderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
fn payload(event: &str, command: &str) -> Value {
    json!({"hook_event_name":event,"tool_name":"Bash","tool_input":{"command":command},"cwd":"/test/repo","tool_use_id":"test-call"})
}
fn native(output: &Output) -> Value {
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn standalone_catalog_and_removed_commands() {
    let output = invoke(&["rules", "--json"], "", None);
    success(&output);
    let rules = native(&output);
    assert!(
        rules
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["id"] == "TS-02"
                && r["body"].as_str().unwrap().contains("Returning a Promise"))
    );
    success(&invoke(&["rules", "rust"], "", None));
    for old in ["RS-06", "RS-14", "W-16", "TASTE-ANSI", "NO-SUCH-RULE"] {
        assert_eq!(invoke(&["rules", old], "", None).status.code(), Some(2));
    }
    for command in ["scan", "codex-app-server", "pkg-rewrite"] {
        assert_eq!(invoke(&[command], "", None).status.code(), Some(2));
    }
}

#[test]
fn native_hook_protocol_and_no_command_rewrites() {
    for host in ["claude", "codex"] {
        let denied = invoke(
            &["hook", host],
            &payload("PreToolUse", "rm -rf /").to_string(),
            None,
        );
        success(&denied);
        assert_eq!(
            native(&denied)["hookSpecificOutput"]["permissionDecision"],
            "deny"
        );
        for command in [
            "npm install",
            "pip install requests",
            "cat > docs/design.md",
            "echo cargo test",
        ] {
            let allowed = invoke(
                &["hook", host],
                &payload("PreToolUse", command).to_string(),
                None,
            );
            success(&allowed);
            assert!(allowed.stdout.is_empty());
        }
    }
}

#[test]
fn malformed_input_fails_without_leaking_payload() {
    for input in [
        "",
        "PRIVATE_SENTINEL",
        "{\"password\":\"PRIVATE_SENTINEL\",",
        "[]",
        "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"/repo\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":42}}",
    ] {
        let output = invoke(&["hook", "codex"], input, None);
        assert_eq!(output.status.code(), Some(2));
        assert!(!String::from_utf8_lossy(&output.stdout).contains("PRIVATE_SENTINEL"));
        assert!(!String::from_utf8_lossy(&output.stderr).contains("PRIVATE_SENTINEL"));
    }
}

#[cfg(unix)]
#[test]
fn codex_feature_install_status_and_uninstall_preserve_user_settings() {
    for original in [
        "",
        "# user note\nmodel = 'user-model'\n[features]\nhooks = false # user comment\nother = true\n",
        "features.hooks = false\nfeatures.other = true\n",
        "features = { hooks = false, other = true }\n",
        "[features]\ncodex_hooks = false\n",
    ] {
        let temp = Temp::new();
        let host_dir = temp.0.join(".codex");
        fs::create_dir(&host_dir).unwrap();
        let path = host_dir.join("config.toml");
        if !original.is_empty() {
            fs::write(&path, original).unwrap();
        }
        let home = temp.0.to_str().unwrap();
        success(&invoke(&["install", "codex", "--home", home], "", None));
        let installed = fs::read_to_string(&path).unwrap();
        let doc = installed.parse::<toml_edit::DocumentMut>().unwrap();
        assert_eq!(doc["features"]["hooks"].as_bool(), Some(true));
        if original.contains("other") {
            assert_eq!(doc["features"]["other"].as_bool(), Some(true));
        }
        if original.contains("# user note") {
            assert!(installed.contains("# user note"));
            assert!(installed.contains("# user comment"));
            assert!(installed.contains("model = 'user-model'"));
        }
        success(&invoke(&["install", "codex", "--home", home], "", None));
        assert_eq!(fs::read_to_string(&path).unwrap(), installed);
        fs::write(&path, "[features]\nhooks = false\n").unwrap();
        let status = invoke(&["status", "codex", "--home", home], "", None);
        assert_eq!(status.status.code(), Some(1));
        assert_eq!(native(&status)["host_hooks_feature_enabled"], false);
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "[features]\nhooks = false\n"
        );
        success(&invoke(&["install", "codex", "--home", home], "", None));
        let enabled = fs::read_to_string(&path).unwrap();
        fs::remove_file(&path).unwrap();
        // Current Codex defaults to enabled when the feature key is absent.
        success(&invoke(&["status", "codex", "--home", home], "", None));
        fs::write(&path, &enabled).unwrap();
        success(&invoke(&["uninstall", "codex", "--home", home], "", None));
        assert_eq!(fs::read_to_string(&path).unwrap(), enabled);
    }
}

#[cfg(unix)]
#[test]
fn invalid_codex_feature_config_fails_before_installation() {
    for text in [
        "[broken",
        "features = false",
        "[features]\nhooks = 'false'\n",
    ] {
        let temp = Temp::new();
        fs::create_dir(temp.0.join(".codex")).unwrap();
        let path = temp.0.join(".codex/config.toml");
        fs::write(&path, text).unwrap();
        let output = invoke(
            &["install", "codex", "--home", temp.0.to_str().unwrap()],
            "",
            None,
        );
        assert_eq!(output.status.code(), Some(2));
        assert_eq!(fs::read_to_string(&path).unwrap(), text);
        assert!(!temp.0.join(".vibeguard").exists());
        assert!(!temp.0.join(".codex/hooks.json").exists());
    }
}

#[cfg(unix)]
#[test]
fn codex_feature_uses_selected_host_directory() {
    let temp = Temp::new();
    let custom = temp.0.join("custom-codex");
    fs::create_dir(&custom).unwrap();
    fs::write(custom.join("config.toml"), "[features]\nhooks = false\n").unwrap();
    let output = Command::new(BIN)
        .args(["install", "codex"])
        .env("HOME", &temp.0)
        .env("CODEX_HOME", &custom)
        .output()
        .unwrap();
    success(&output);
    assert!(!temp.0.join(".codex").exists());
    assert!(
        fs::read_to_string(custom.join("config.toml"))
            .unwrap()
            .contains("hooks = true")
    );
    success(&invoke(
        &["install", "claude", "--home", temp.0.to_str().unwrap()],
        "",
        None,
    ));
    assert!(!temp.0.join(".claude/config.toml").exists());
}

#[test]
fn native_hooks_preserve_shell_argument_semantics() {
    // Commands are protocol data only; none is executed by a shell.
    for host in ["claude", "codex"] {
        for (command, blocked) in [
            ("rm -rf '$HOME'", false),
            ("rm -rf '~'", false),
            ("rm -rf \"$HOME\"", true),
            ("rm -rf '/etc'", true),
            ("git clean -fd -- -n", true),
            ("git clean --force -d", true),
            ("git clean -f --no-force", false),
            ("git clean -nf --no-dry-run", true),
            ("git clean -f -e -n", true),
            ("git clean -f > '-n'", true),
            ("git clean -f >'-n'", true),
            ("git clean -f >out -n", false),
            ("git 'clean' -f", true),
            ("git clean -nfd", false),
            ("echo ok;# note; git clean -fd", false),
            ("cat <<'EOF'\ngit clean -fd\nEOF", false),
            ("printf '%s' '名前; git clean -fd'", false),
        ] {
            let output = invoke(
                &["hook", host],
                &payload("PreToolUse", command).to_string(),
                None,
            );
            success(&output);
            assert!(output.stderr.is_empty(), "{host}: {command}");
            if blocked {
                assert_eq!(
                    native(&output)["hookSpecificOutput"]["permissionDecision"],
                    "deny",
                    "{host}: {command}"
                );
            } else {
                assert!(output.stdout.is_empty(), "{host}: {command}");
            }
        }
    }
}

#[test]
fn observations_record_only_reported_outcomes_and_never_raw_commands() {
    let temp = Temp::new();
    let path = temp.0.to_str().unwrap();
    for (response, outcome) in [
        (
            json!({"exit_code":0,"stdout":"PRIVATE_SENTINEL"}),
            "exited_zero",
        ),
        (json!({"exit_code":7}), "exited_nonzero"),
        (json!({"session_id":22}), "running"),
        (json!({"interrupted":true}), "interrupted"),
        (
            json!({"stdout":"cargo test passed"}),
            "exit_status_unavailable",
        ),
    ] {
        let mut event = payload("PostToolUse", "echo PRIVATE_SENTINEL cargo test");
        event["tool_response"] = response;
        success(&invoke(
            &["hook", "codex", "--state-dir", path],
            &event.to_string(),
            None,
        ));
        let text = fs::read_to_string(temp.0.join("codex.json")).unwrap();
        assert!(!text.contains("PRIVATE_SENTINEL"));
        let record: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(record["outcome"], outcome);
        assert!(record.get("verified").is_none());
    }
    success(&invoke(
        &["hook", "codex", "--state-dir", path],
        &payload("PreToolUse", "cargo test").to_string(),
        None,
    ));
    let record: Value =
        serde_json::from_slice(&fs::read(temp.0.join("codex.json")).unwrap()).unwrap();
    assert_eq!(record["outcome"], "requested");
    let mut failure = payload("PostToolUseFailure", "cargo test");
    failure["error"] = json!("Exit code 1\nPRIVATE_SENTINEL");
    success(&invoke(
        &["hook", "claude", "--state-dir", path],
        &failure.to_string(),
        None,
    ));
    assert_eq!(
        invoke(&["hook", "codex"], &failure.to_string(), None)
            .status
            .code(),
        Some(2)
    );
}

#[cfg(unix)]
#[test]
fn install_execute_and_uninstall_preserve_user_content() {
    for host in ["claude", "codex"] {
        let temp = Temp::new();
        let home = temp.0.join("developer's home $(touch SHOULD_NOT_EXIST)");
        let host_dir = home.join(format!(".{host}"));
        fs::create_dir_all(&host_dir).unwrap();
        let config_path = host_dir.join(if host == "codex" {
            "hooks.json"
        } else {
            "settings.json"
        });
        let instructions = host_dir.join(if host == "codex" {
            "AGENTS.md"
        } else {
            "CLAUDE.md"
        });
        let user_hook = json!({"matcher":"Bash","hooks":[{"type":"command","command":"echo user-hook","timeout":17}]});
        let original_config =
            json!({"custom":{"value":42},"hooks":{"PreToolUse":[user_hook.clone()]}});
        fs::write(&config_path, original_config.to_string()).unwrap();
        let user_text = "User-owned instructions\r\nNo final newline";
        fs::write(&instructions, user_text).unwrap();
        let home_arg = home.to_str().unwrap();
        success(&invoke(&["install", host, "--home", home_arg], "", None));
        let first_config = fs::read(&config_path).unwrap();
        let first_instructions = fs::read(&instructions).unwrap();
        success(&invoke(&["install", host, "--home", home_arg], "", None));
        assert_eq!(fs::read(&config_path).unwrap(), first_config);
        assert_eq!(fs::read(&instructions).unwrap(), first_instructions);
        let config: Value = serde_json::from_slice(&first_config).unwrap();
        assert_eq!(config["custom"], original_config["custom"]);
        assert_eq!(config["hooks"]["PreToolUse"][0], user_hook);
        let state = invoke(&["status", host, "--home", home_arg], "", None);
        success(&state);
        assert_eq!(native(&state)["host_trust"], "not_observed");
        assert_eq!(native(&state)["last_observation"], Value::Null);

        // Execute the exact generated command as the host does, including
        // spaces, quotes and shell metacharacters in the installation path.
        let command = config["hooks"]["PreToolUse"][1]["hooks"][0]["command"]
            .as_str()
            .unwrap();
        let mut child = Command::new("sh")
            .args(["-c", command])
            .current_dir(&temp.0)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(
                payload("PreToolUse", "git clean -fd")
                    .to_string()
                    .as_bytes(),
            )
            .unwrap();
        let output = child.wait_with_output().unwrap();
        success(&output);
        assert_eq!(
            native(&output)["hookSpecificOutput"]["permissionDecision"],
            "deny"
        );
        assert!(!temp.0.join("SHOULD_NOT_EXIST").exists());

        success(&invoke(&["uninstall", host, "--home", home_arg], "", None));
        assert_eq!(fs::read_to_string(&instructions).unwrap(), user_text);
        let final_config: Value = serde_json::from_slice(&fs::read(&config_path).unwrap()).unwrap();
        assert_eq!(final_config["custom"], original_config["custom"]);
        assert_eq!(final_config["hooks"]["PreToolUse"], json!([user_hook]));
        assert_eq!(
            invoke(&["status", host, "--home", home_arg], "", None)
                .status
                .code(),
            Some(1)
        );
        success(&invoke(&["uninstall", host, "--home", home_arg], "", None));
    }
}

#[cfg(unix)]
#[test]
fn status_requires_current_core_content_and_reinstall_repairs_it() {
    for host in ["claude", "codex"] {
        let temp = Temp::new();
        let home = temp.0.to_str().unwrap();
        let instructions = temp.0.join(format!(".{host}")).join(if host == "codex" {
            "AGENTS.md"
        } else {
            "CLAUDE.md"
        });
        success(&invoke(&["install", host, "--home", home], "", None));
        let current = fs::read_to_string(&instructions).unwrap();
        let prefix = "User-owned prefix\r\n";
        let suffix = "User-owned suffix without final newline";
        for stale in [
            String::new(),
            "<!-- vibeguard-core:start -->\n<!-- vibeguard-core:end -->\n".to_string(),
            current.replace("- U-29: Preserve the operation's error contract.\n", ""),
            current.replace(".vibeguard/bin/", ".vibeguard/old-bin/"),
        ] {
            let edited = format!("{prefix}{stale}{suffix}");
            fs::write(&instructions, &edited).unwrap();
            let state = invoke(&["status", host, "--home", home], "", None);
            assert_eq!(state.status.code(), Some(1), "{host}: {stale}");
            assert_eq!(native(&state)["core_present"], false);
            assert_eq!(fs::read_to_string(&instructions).unwrap(), edited);
            success(&invoke(&["install", host, "--home", home], "", None));
            let state = invoke(&["status", host, "--home", home], "", None);
            success(&state);
            assert_eq!(native(&state)["core_present"], true);
            let repaired = fs::read_to_string(&instructions).unwrap();
            assert_eq!(repaired.replace(&current, ""), format!("{prefix}{suffix}"));
        }
        for valid in [
            format!("{prefix}{}{suffix}", current.replace('\n', "\r\n")),
            current.trim_end_matches('\n').to_string(),
        ] {
            fs::write(&instructions, &valid).unwrap();
            let state = invoke(&["status", host, "--home", home], "", None);
            success(&state);
            assert_eq!(native(&state)["core_present"], true);
            assert_eq!(fs::read_to_string(&instructions).unwrap(), valid);
        }
        let malformed = "<!-- vibeguard-core:start -->\nincomplete";
        fs::write(&instructions, malformed).unwrap();
        let state = invoke(&["status", host, "--home", home], "", None);
        assert_eq!(state.status.code(), Some(2));
        assert_eq!(fs::read_to_string(&instructions).unwrap(), malformed);
    }
}

#[cfg(unix)]
#[test]
fn corrupt_config_or_instructions_fail_before_installation() {
    for (config, instructions) in [
        ("{\"token\":\"PRIVATE_SENTINEL\",", "user content"),
        ("[]", "user content"),
        ("{\"hooks\":{\"PreToolUse\":false}}", "user content"),
        ("{}", "<!-- vibeguard-core:start -->\nincomplete"),
    ] {
        let temp = Temp::new();
        let host_dir = temp.0.join(".codex");
        fs::create_dir(&host_dir).unwrap();
        let config_path = host_dir.join("hooks.json");
        let instructions_path = host_dir.join("AGENTS.md");
        fs::write(&config_path, config).unwrap();
        fs::write(&instructions_path, instructions).unwrap();
        let output = invoke(
            &["install", "codex", "--home", temp.0.to_str().unwrap()],
            "",
            None,
        );
        assert_eq!(output.status.code(), Some(2));
        assert_eq!(fs::read_to_string(&config_path).unwrap(), config);
        assert_eq!(
            fs::read_to_string(&instructions_path).unwrap(),
            instructions
        );
        assert!(!temp.0.join(".vibeguard").exists());
        assert!(!String::from_utf8_lossy(&output.stderr).contains("PRIVATE_SENTINEL"));
    }
}

#[cfg(unix)]
#[test]
fn symlinks_invalid_utf8_and_permissions_are_respected() {
    use std::os::unix::{fs::PermissionsExt, fs::symlink};
    let temp = Temp::new();
    let host_dir = temp.0.join(".codex");
    fs::create_dir(&host_dir).unwrap();
    let target = temp.0.join("user.json");
    fs::write(&target, "{}").unwrap();
    let config = host_dir.join("hooks.json");
    symlink(&target, &config).unwrap();
    assert_eq!(
        invoke(
            &["install", "codex", "--home", temp.0.to_str().unwrap()],
            "",
            None
        )
        .status
        .code(),
        Some(2)
    );
    assert_eq!(fs::read_to_string(&target).unwrap(), "{}");
    fs::remove_file(&config).unwrap();
    fs::write(&config, "{}").unwrap();
    fs::set_permissions(&config, fs::Permissions::from_mode(0o640)).unwrap();
    let instructions = host_dir.join("AGENTS.md");
    fs::write(&instructions, [0xff, 0xfe]).unwrap();
    assert_eq!(
        invoke(
            &["install", "codex", "--home", temp.0.to_str().unwrap()],
            "",
            None
        )
        .status
        .code(),
        Some(2)
    );
    assert_eq!(fs::read(&instructions).unwrap(), [0xff, 0xfe]);
    fs::write(&instructions, "user").unwrap();
    success(&invoke(
        &["install", "codex", "--home", temp.0.to_str().unwrap()],
        "",
        None,
    ));
    assert_eq!(
        fs::metadata(config).unwrap().permissions().mode() & 0o777,
        0o640
    );
}

fn git(repo: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args([
            "-c",
            "commit.gpgsign=false",
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
        ])
        .args(args)
        .output()
        .unwrap();
    success(&output);
    String::from_utf8(output.stdout).unwrap().trim().to_string()
}

#[test]
fn git_ancestry_is_checked_with_real_commits() {
    let temp = Temp::new();
    git(&temp.0, &["init", "-q"]);
    fs::write(temp.0.join("value"), "base").unwrap();
    git(&temp.0, &["add", "value"]);
    git(&temp.0, &["commit", "-qm", "base"]);
    let base = git(&temp.0, &["rev-parse", "HEAD"]);
    fs::write(temp.0.join("value"), "next").unwrap();
    git(&temp.0, &["commit", "-qam", "next"]);
    let next = git(&temp.0, &["rev-parse", "HEAD"]);
    git(&temp.0, &["checkout", "--detach", &base]);
    fs::write(temp.0.join("value"), "divergent").unwrap();
    git(&temp.0, &["commit", "-qam", "divergent"]);
    let divergent = git(&temp.0, &["rev-parse", "HEAD"]);
    let zero = "0".repeat(base.len());
    for (local, remote, exit) in [
        (&next, &base, 0),
        (&next, &zero, 0),
        (&zero, &next, 1),
        (&divergent, &next, 1),
    ] {
        let record = format!("refs/heads/main {local} refs/heads/main {remote}\n");
        assert_eq!(
            invoke(&["pre-push"], &record, Some(&temp.0)).status.code(),
            Some(exit)
        );
    }
    let missing = "1".repeat(base.len());
    let record = format!("refs/heads/main {next} refs/heads/main {missing}\n");
    assert_eq!(
        invoke(&["pre-push"], &record, Some(&temp.0)).status.code(),
        Some(2)
    );
    assert_eq!(
        invoke(&["pre-push"], "malformed\n", Some(&temp.0))
            .status
            .code(),
        Some(2)
    );
}

#[test]
fn git_tag_updates_use_remote_namespace_and_object_identity() {
    let temp = Temp::new();
    git(&temp.0, &["init", "-q"]);
    fs::write(temp.0.join("value"), "base").unwrap();
    git(&temp.0, &["add", "value"]);
    git(&temp.0, &["commit", "-qm", "base"]);
    let base = git(&temp.0, &["rev-parse", "HEAD"]);
    let blob = git(&temp.0, &["rev-parse", "HEAD:value"]);
    let tree = git(&temp.0, &["rev-parse", "HEAD^{tree}"]);
    git(
        &temp.0,
        &["-c", "tag.gpgsign=false", "tag", "-am", "first", "first"],
    );
    git(
        &temp.0,
        &["-c", "tag.gpgsign=false", "tag", "-am", "second", "second"],
    );
    let first = git(&temp.0, &["rev-parse", "refs/tags/first"]);
    let second = git(&temp.0, &["rev-parse", "refs/tags/second"]);
    fs::write(temp.0.join("value"), "next").unwrap();
    git(&temp.0, &["commit", "-qam", "next"]);
    let next = git(&temp.0, &["rev-parse", "HEAD"]);
    let zero = "0".repeat(base.len());
    let mut failures = Vec::new();
    for (name, local, remote, expected) in [
        ("lightweight descendant replacement", &next, &base, 1),
        ("annotated same-commit replacement", &second, &first, 1),
        ("blob replacement", &blob, &base, 1),
        ("tree replacement", &tree, &blob, 1),
        ("new lightweight", &base, &zero, 0),
        ("new annotated", &first, &zero, 0),
        ("new blob", &blob, &zero, 0),
        ("new tree", &tree, &zero, 0),
        ("unchanged lightweight", &base, &base, 0),
        ("unchanged annotated", &first, &first, 0),
        ("unchanged blob", &blob, &blob, 0),
        ("unchanged tree", &tree, &tree, 0),
        ("deletion", &zero, &base, 1),
    ] {
        // A local branch or expression can target a remote tag.
        let record = format!("refs/heads/main {local} refs/tags/release {remote}\n");
        let output = invoke(&["pre-push"], &record, Some(&temp.0));
        if output.status.code() != Some(expected) {
            failures.push(format!(
                "{name}: expected {expected}, got {:?}",
                output.status.code()
            ));
        }
        if expected == 1 && !String::from_utf8_lossy(&output.stderr).contains("refs/tags/release") {
            failures.push(format!("{name}: diagnostic omitted the remote ref"));
        }
    }
    // A local tag pushed outside refs/tags still uses the existing ancestry policy.
    for destination in ["refs/heads/main", "refs/custom/release"] {
        let record = format!("refs/tags/release {next} {destination} {base}\n");
        success(&invoke(&["pre-push"], &record, Some(&temp.0)));
    }
    for (destination, local, remote, expected) in [
        ("refs/heads/main", &first, &base, 1),
        ("refs/heads/main", &first, &zero, 1),
        ("refs/heads/main", &base, &first, 1),
        ("refs/custom/release", &second, &first, 0),
        ("refs/custom/release", &blob, &zero, 0),
        ("refs/custom/release", &blob, &blob, 0),
        ("refs/custom/release", &tree, &tree, 0),
        ("refs/custom/release", &blob, &base, 1),
        ("refs/custom/release", &tree, &blob, 1),
        ("refs/custom/release", &base, &blob, 1),
    ] {
        let record = format!("HEAD {local} {destination} {remote}\n");
        let output = invoke(&["pre-push"], &record, Some(&temp.0));
        if output.status.code() != Some(expected) {
            failures.push(format!(
                "{record:?}: expected {expected}, got {:?}",
                output.status.code()
            ));
        }
        if expected == 1 {
            assert!(!String::from_utf8_lossy(&output.stderr).contains("fetch"));
        }
    }
    let missing = "1".repeat(base.len());
    let record = format!("HEAD {next} refs/custom/release {missing}\n");
    assert_eq!(
        invoke(&["pre-push"], &record, Some(&temp.0)).status.code(),
        Some(2)
    );
    let records = format!(
        "refs/tags/new {first} refs/tags/new {zero}\n\
         refs/tags/same {blob} refs/tags/same {blob}\n\
         HEAD {blob} refs/custom/blob {blob}\n\
         HEAD {tree} refs/custom/tree {tree}\n\
         refs/heads/main {next} refs/tags/release {base}\n"
    );
    let output = invoke(&["pre-push"], &records, Some(&temp.0));
    if output.status.code() != Some(1) {
        failures.push(format!(
            "multiple records: expected 1, got {:?}",
            output.status.code()
        ));
    }
    assert!(String::from_utf8_lossy(&output.stderr).contains("refs/tags/release"));
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn git_pre_push_accepts_sha1_and_sha256_oid_formats() {
    for width in [40, 64] {
        let oid = "a".repeat(width);
        let zero = "0".repeat(width);
        let record = format!("refs/tags/new {oid} refs/tags/new {zero}\n");
        success(&invoke(&["pre-push"], &record, None));
        for destination in ["refs/heads/main", "refs/tags/same", "refs/custom/same"] {
            let record = format!("HEAD {oid} {destination} {oid}\n");
            success(&invoke(&["pre-push"], &record, None));
        }
    }
    for oid in ["a".repeat(39), "a".repeat(63), "g".repeat(64)] {
        let zero = "0".repeat(64);
        for (local, remote) in [(&oid, &zero), (&zero, &oid)] {
            let record = format!("refs/tags/new {local} refs/tags/new {remote}\n");
            assert_eq!(invoke(&["pre-push"], &record, None).status.code(), Some(2));
        }
    }
}

#[cfg(unix)]
#[test]
fn git_installer_does_not_overwrite_a_user_hook() {
    let temp = Temp::new();
    let repo = temp.0.join("repo");
    fs::create_dir(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    // Override any developer-global hook path only in this test repository.
    git(&repo, &["config", "core.hooksPath", ".git/hooks"]);
    let hook = repo.join(".git/hooks/pre-push");
    fs::write(&hook, "#!/bin/sh\necho custom\n").unwrap();
    let args = [
        "install",
        "git",
        "--repo",
        repo.to_str().unwrap(),
        "--home",
        temp.0.to_str().unwrap(),
    ];
    assert_eq!(invoke(&args, "", None).status.code(), Some(2));
    assert_eq!(
        fs::read_to_string(&hook).unwrap(),
        "#!/bin/sh\necho custom\n"
    );
    fs::remove_file(&hook).unwrap();
    success(&invoke(&args, "", None));
    assert!(fs::read_to_string(&hook).unwrap().contains("pre-push"));
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&hook, fs::Permissions::from_mode(0o644)).unwrap();
    let mut status_args = args;
    status_args[0] = "status";
    assert_eq!(invoke(&status_args, "", None).status.code(), Some(1));
    success(&invoke(&args, "", None));
    assert_ne!(fs::metadata(&hook).unwrap().permissions().mode() & 0o111, 0);
    success(&invoke(
        &[
            "status",
            "git",
            "--repo",
            repo.to_str().unwrap(),
            "--home",
            temp.0.to_str().unwrap(),
        ],
        "",
        None,
    ));
    success(&invoke(
        &[
            "uninstall",
            "git",
            "--repo",
            repo.to_str().unwrap(),
            "--home",
            temp.0.to_str().unwrap(),
        ],
        "",
        None,
    ));
    assert!(!hook.exists());
}

#[cfg(unix)]
#[test]
fn reinstall_repairs_only_owned_executable_permissions() {
    use std::os::unix::fs::PermissionsExt;
    let temp = Temp::new();
    let home = temp.0.to_str().unwrap();
    let binary = temp.0.join(".vibeguard/bin/vibeguard-runtime");
    let config = temp.0.join(".codex/hooks.json");
    success(&invoke(&["install", "codex", "--home", home], "", None));
    fs::set_permissions(&config, fs::Permissions::from_mode(0o640)).unwrap();
    for (changed, mode) in [(false, 0o644), (false, 0o655), (true, 0o644)] {
        if changed {
            fs::write(&binary, "old binary").unwrap();
        }
        fs::set_permissions(&binary, fs::Permissions::from_mode(mode)).unwrap();
        let status = invoke(&["status", "codex", "--home", home], "", None);
        assert_eq!(status.status.code(), Some(1));
        assert_eq!(native(&status)["binary_executable"], false);
        success(&invoke(&["install", "codex", "--home", home], "", None));
        success(&Command::new(&binary).arg("--version").output().unwrap());
        assert_eq!(
            fs::metadata(&config).unwrap().permissions().mode() & 0o777,
            0o640
        );
    }
}

#[cfg(not(unix))]
#[test]
fn unsupported_native_installation_is_explicit() {
    let temp = Temp::new();
    let output = invoke(
        &["install", "codex", "--home", temp.0.to_str().unwrap()],
        "",
        None,
    );
    assert_eq!(output.status.code(), Some(2));
    assert!(!temp.0.join(".codex").exists());
}
