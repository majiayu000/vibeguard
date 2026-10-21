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

#[cfg(unix)]
fn snapshot(path: &Path) -> std::collections::BTreeMap<PathBuf, (u32, Vec<u8>)> {
    use std::os::unix::fs::PermissionsExt;
    let mut result = std::collections::BTreeMap::new();
    for entry in fs::read_dir(path).unwrap() {
        let path = entry.unwrap().path();
        let metadata = fs::metadata(&path).unwrap();
        result.insert(
            path.clone(),
            (
                metadata.permissions().mode(),
                if metadata.is_file() {
                    fs::read(&path).unwrap()
                } else {
                    Vec::new()
                },
            ),
        );
        if metadata.is_dir() {
            result.extend(snapshot(&path));
        }
    }
    result
}

#[cfg(unix)]
#[test]
fn installation_preview_is_read_only_and_matches_host_changes() {
    for host in ["claude", "codex", "grok"] {
        let temp = Temp::new();
        let home = temp.0.join("new-home");
        let args = [
            "install",
            host,
            "--dry-run",
            "--home",
            home.to_str().unwrap(),
        ];
        let output = invoke(&args, "", None);
        success(&output);
        assert!(!home.exists(), "preview created the home or setup locks");
        let plan = native(&output);
        assert_eq!(plan["dry_run"], true);
        assert_eq!(
            plan["details"]["matcher"],
            if host == "grok" {
                "run_terminal_command"
            } else {
                "Bash"
            }
        );
        assert_eq!(plan["host_trust"], "not_observed");
        assert!(
            plan["changes"]
                .as_array()
                .unwrap()
                .iter()
                .any(|c| c["operation"] == "register_hooks")
        );
        let dir = home.join(format!(".{host}"));
        fs::create_dir_all(&dir).unwrap();
        let config_path = dir.join(match host {
            "codex" => "hooks.json",
            "grok" => "hooks/vibeguard.json",
            _ => "settings.json",
        });
        fs::create_dir_all(config_path.parent().unwrap()).unwrap();
        fs::write(&config_path, "{\"disableAllHooks\":true,\"user\":7,\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"echo user\"}]}]}}").unwrap();
        let instructions = dir.join(match host {
            "codex" => "AGENTS.md",
            "grok" => "rules/vibeguard.md",
            _ => "CLAUDE.md",
        });
        fs::create_dir_all(instructions.parent().unwrap()).unwrap();
        fs::write(&instructions, "user note\r\n<!-- vibeguard-core:start -->\r\nold owned text\r\n<!-- vibeguard-core:end -->\r\nkeep me").unwrap();
        if host == "codex" {
            fs::write(
                dir.join("config.toml"),
                "# user comment\nmodel = 'user-model'\n[features]\nhooks = false\n",
            )
            .unwrap();
        }
        let before = snapshot(&home);
        let output = invoke(&args, "", None);
        success(&output);
        assert_eq!(snapshot(&home), before);
        let plan = native(&output);
        assert_eq!(plan["details"]["host_hook_disable_flag"], true);
        assert!(String::from_utf8_lossy(&output.stderr).contains("Host hooks are disabled"));
        success(&invoke(
            &["install", host, "--home", home.to_str().unwrap()],
            "",
            None,
        ));
        for change in plan["changes"].as_array().unwrap() {
            assert!(Path::new(change["path"].as_str().unwrap()).is_file());
        }
        let config: Value = serde_json::from_slice(&fs::read(&config_path).unwrap()).unwrap();
        assert_eq!(config["user"], 7);
        assert_eq!(config["disableAllHooks"], true);
        assert_eq!(
            config["hooks"]["PreToolUse"][0]["hooks"][0]["command"],
            "echo user"
        );
        assert_eq!(
            fs::read_to_string(instructions).unwrap(),
            "user note\r\nkeep me"
        );
        let before = snapshot(&home);
        let output = invoke(&args, "", None);
        success(&output);
        assert!(native(&output)["changes"].as_array().unwrap().is_empty());
        assert_eq!(snapshot(&home), before);
    }
}

#[cfg(unix)]
#[test]
fn installation_preview_preserves_rejections_and_git_ownership() {
    let temp = Temp::new();
    let home = temp.0.join("home");
    let repo = temp.0.join("repo");
    fs::create_dir(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    git(&repo, &["config", "core.hooksPath", ".git/hooks"]);
    let args = [
        "install",
        "git",
        "--home",
        home.to_str().unwrap(),
        "--repo",
        repo.to_str().unwrap(),
        "--dry-run",
    ];
    let output = invoke(&args, "", None);
    success(&output);
    assert!(!home.exists());
    let hook = repo.join(".git/hooks/pre-push");
    assert!(!hook.exists());
    assert!(
        native(&output)["changes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c["operation"] == "register_pre_push")
    );
    fs::write(&hook, "#!/bin/sh\necho user\n").unwrap();
    let output = invoke(&args, "", None);
    assert_eq!(output.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stderr).contains("user-managed"));
    assert_eq!(fs::read_to_string(&hook).unwrap(), "#!/bin/sh\necho user\n");
    assert!(!home.exists());
    fs::create_dir_all(home.join(".codex")).unwrap();
    fs::write(home.join(".codex/hooks.json"), "invalid JSON").unwrap();
    assert_eq!(
        invoke(
            &[
                "install",
                "codex",
                "--dry-run",
                "--home",
                home.to_str().unwrap()
            ],
            "",
            None
        )
        .status
        .code(),
        Some(2)
    );
    assert!(!home.join(".vibeguard").exists());
    for action in ["status", "uninstall"] {
        assert_eq!(
            invoke(
                &[
                    action,
                    "claude",
                    "--dry-run",
                    "--home",
                    home.to_str().unwrap()
                ],
                "",
                None
            )
            .status
            .code(),
            Some(2)
        );
    }
    assert_eq!(
        invoke(
            &[
                "install",
                "claude",
                "--dry-run",
                "--dry-run",
                "--home",
                home.to_str().unwrap()
            ],
            "",
            None
        )
        .status
        .code(),
        Some(2)
    );
}
fn native(output: &Output) -> Value {
    serde_json::from_slice(&output.stdout).unwrap()
}

#[cfg(unix)]
#[test]
fn claude_install_removes_retired_skills_loader_registrations() {
    let temp = Temp::new();
    let home = temp.0.join("home with spaces");
    let dir = home.join(".claude");
    fs::create_dir_all(&dir).unwrap();
    let config_path = dir.join("settings.json");
    let command_hook = |command: &str| json!({"type":"command","command":command});
    let wrapper = command_hook(&format!(
        "bash '{}/.vibeguard/run-hook.sh' skills-loader.sh",
        home.display()
    ));
    let duplicate = json!({"hooks":[wrapper]});
    let retired = [
        "/home/old/.vibeguard/installed/hooks/skills-loader.sh",
        "bash ~/.vibeguard/installed/hooks/skills-loader.sh",
        "/bin/bash \"${HOME}/.vibeguard/installed/hooks/skills-loader.sh\"",
        "\"$HOME/.vibeguard/installed/hooks/skills-loader.sh\"",
        "~/.vibeguard/run-hook.sh skills-loader.sh",
        "bash '/home/old (1)/.vibeguard/installed/hooks/skills-loader.sh'",
        "/bin/sh \"/home/old #1/.vibeguard/run-hook.sh\" 'skills-loader.sh'",
        "bash '/home/a; b/.vibeguard/dist/current/hooks/skills-loader.sh'",
        "bash '/home/a & b/.vibeguard/run-hook.sh' 'skills-loader.sh'",
    ];
    let kept = vec![
        command_hook("skills-loader.sh"),
        command_hook("./hooks/skills-loader.sh"),
        command_hook("bash /opt/acme/skills-loader.sh"),
        command_hook("bash '/opt/VibeGuard (old)/hooks/skills-loader.sh'"),
        command_hook("echo skills-loader.sh"),
        command_hook("cat /old/vibeguard/hooks/skills-loader.sh"),
        command_hook("bash /custom/audit.sh skills-loader.sh"),
        command_hook("bash ~/.vibeguard/run-hook.sh pre-bash-guard.sh"),
        command_hook("bash /custom/run-hook.sh skills-loader.sh"),
        command_hook("bash /old/hooks/skills-loader.sh.backup"),
        command_hook("bash -c 'echo skills-loader.sh'"),
        command_hook("echo keep; bash /old/hooks/skills-loader.sh"),
        command_hook("bash \"/custom/\\skills-loader.sh\""),
        command_hook("bash '/old/hooks/skills-loader.sh"),
        command_hook("bash ~/.vibeguard/installed/hooks/skills-loader.sh && echo keep"),
        command_hook("bash \"$(echo /home/old)/.vibeguard/installed/hooks/skills-loader.sh\""),
        json!({"type":"prompt","prompt":"Discuss skills-loader.sh","command":"skills-loader.sh"}),
    ];
    let mut handlers = kept.clone();
    handlers.extend(retired.iter().map(|command| command_hook(command)));
    let empty_group = json!({"matcher":"keep-empty","hooks":[]});
    let initial = json!({
        "custom":{"keep":true}, "disableAllHooks":true,
        "hooks":{
            "SessionStart":vec![duplicate; 5],
            "PreToolUse":[{"matcher":"Read","custom":7,"hooks":handlers},empty_group],
            "Stop":[{"hooks":[command_hook("echo user-stop")]}]
        }
    });
    let initial_bytes = serde_json::to_vec_pretty(&initial).unwrap();
    fs::write(&config_path, &initial_bytes).unwrap();
    let home_str = home.to_str().unwrap();
    let status = invoke(&["status", "claude", "--home", home_str], "", None);
    assert_eq!(status.status.code(), Some(1));
    assert_eq!(fs::read(&config_path).unwrap(), initial_bytes);
    assert!(!home.join(".vibeguard").exists());
    let preview = invoke(
        &["install", "claude", "--dry-run", "--home", home_str],
        "",
        None,
    );
    success(&preview);
    assert_eq!(fs::read(&config_path).unwrap(), initial_bytes);
    assert!(!home.join(".vibeguard").exists());
    assert!(!dir.join(".vibeguard-setup.lock").exists());
    success(&invoke(
        &["install", "claude", "--home", home_str],
        "",
        None,
    ));
    let installed = fs::read(&config_path).unwrap();
    let config: Value = serde_json::from_slice(&installed).unwrap();
    assert_eq!(config["hooks"]["SessionStart"], json!([]));
    assert_eq!(config["custom"], initial["custom"]);
    assert_eq!(config["disableAllHooks"], true);
    assert_eq!(config["hooks"]["Stop"], initial["hooks"]["Stop"]);
    assert_eq!(
        config["hooks"]["PreToolUse"][0],
        json!({"matcher":"Read","custom":7,"hooks":kept})
    );
    assert_eq!(config["hooks"]["PreToolUse"][1], empty_group);
    assert_eq!(config["hooks"]["PreToolUse"].as_array().unwrap().len(), 3);
    assert!(
        native(&preview)["changes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|change| {
                change["operation"] == "remove_retired_skills_loader_hooks"
                    && change["path"] == json!(config_path)
                    && change["handler_count"] == 5 + retired.len()
            })
    );
    assert!(
        String::from_utf8_lossy(&preview.stderr).contains("remove_retired_skills_loader_hooks")
    );
    success(&invoke(
        &["install", "claude", "--home", home_str],
        "",
        None,
    ));
    assert_eq!(fs::read(&config_path).unwrap(), installed);
    let preview = invoke(
        &["install", "claude", "--dry-run", "--home", home_str],
        "",
        None,
    );
    success(&preview);
    assert!(native(&preview)["changes"].as_array().unwrap().is_empty());
}

#[cfg(unix)]
#[test]
fn retired_skills_loader_cleanup_is_scoped_to_claude_install() {
    for (action, host, relative_config) in [
        ("uninstall", "claude", ".claude/settings.json"),
        ("install", "codex", ".codex/hooks.json"),
        ("install", "grok", ".grok/hooks/vibeguard.json"),
    ] {
        let temp = Temp::new();
        let config_path = temp.0.join(relative_config);
        fs::create_dir_all(config_path.parent().unwrap()).unwrap();
        let initial = json!({"hooks":{"SessionStart":[{"hooks":[{
            "type":"command","command":"bash ~/.vibeguard/run-hook.sh skills-loader.sh"
        }]}]}});
        fs::write(&config_path, initial.to_string()).unwrap();
        success(&invoke(
            &[action, host, "--home", temp.0.to_str().unwrap()],
            "",
            None,
        ));
        let config: Value = serde_json::from_slice(&fs::read(&config_path).unwrap()).unwrap();
        assert_eq!(
            config["hooks"]["SessionStart"],
            initial["hooks"]["SessionStart"]
        );
    }
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
    for host in ["claude", "codex", "dsh"] {
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
fn native_hooks_preserve_simple_command_lexical_boundaries() {
    // These strings are JSON payload data; no proposed shell command is executed.
    for host in ["claude", "codex"] {
        for (command, denied) in [
            ("git\nrm -rf /etc", true),
            ("rm\ngit clean -fd", true),
            ("git checkout . 2>/tmp/vibeguard-log", true),
            ("git restore -- . 2>>/tmp/vibeguard-log", true),
            ("git checkout . 0</tmp/vibeguard-input", true),
            ("rm -rf 2>&1 /etc", true),
            ("git clean 2>&1 -fd", true),
            ("git clean -f 2>&1 -n", false),
            ("git clean -f >| /tmp/vibeguard-log -n", false),
            ("git clean -f &>/tmp/vibeguard-log -n", false),
            ("'echo' git clean -fd", false),
            ("'/bin/printf' '%s\\n' rm -rf /etc", false),
            ("echo \\<<EOF\ngit clean -fd", true),
            ("cat <<EOF-END\nEOF-END\ngit clean -fd", true),
            ("cat <<EOF-END\ngit clean -fd\nEOF-END", false),
        ] {
            let output = invoke(
                &["hook", host],
                &payload("PreToolUse", command).to_string(),
                None,
            );
            success(&output);
            assert!(output.stderr.is_empty(), "{host}: {command:?}");
            if denied {
                assert!(!output.stdout.is_empty(), "{host}: {command:?}");
                assert_eq!(
                    native(&output)["hookSpecificOutput"]["permissionDecision"],
                    "deny",
                    "{host}: {command:?}"
                );
            } else {
                assert!(output.stdout.is_empty(), "{host}: {command:?}");
            }
        }
    }
}

#[test]
fn native_hooks_preserve_carriage_returns_in_heredoc_delimiters() {
    // Commands stay JSON data: exercise both native hook protocols without
    // executing the proposed shell commands.
    for host in ["claude", "codex"] {
        for (command, denied) in [
            ("cat <<EOF\nbody\nEOF\ngit clean -fd\n", true),
            ("cat <<EOF\r\nbody\r\nEOF\r\ngit clean -fd\n", true),
            ("cat <<'EOF'\r\nbody\r\nEOF\r\ngit clean -fd\n", true),
            ("cat <<\"EOF\"\r\nbody\r\nEOF\r\ngit clean -fd\n", true),
            ("cat <<'EOF\r'\nbody\nEOF\r\ngit clean -fd\n", true),
            ("cat <<-EOF\r\n\tbody\r\n\tEOF\r\ngit clean -fd\n", true),
            ("cat <<EOF\r\nbody\\\r\nEOF\r\ngit clean -fd\n", true),
            ("cat <<EOF\r\nEO\\\nF\r\ngit clean -fd\n", true),
            ("cat <<A <<B\r\nA\nB\r\ngit clean -fd\n", true),
            ("cat <<EOF\r\r\nEOF\r\r\ngit clean -fd\n", true),
            ("cat <<EOF\nEOF\r\ngit clean -fd\n", false),
            ("cat <<EOF\r\nEOF\ngit clean -fd\n", false),
            ("cat <<EOF\r\nEOF\r\r\ngit clean -fd\n", false),
            ("cat <<'EOF'\r\ngit clean -fd\nEOF\r", false),
            ("cat <<EOF\r\nEOF\r\nprintf '%s' 'git clean -fd'\n", false),
        ] {
            let output = invoke(
                &["hook", host],
                &payload("PreToolUse", command).to_string(),
                None,
            );
            success(&output);
            assert!(output.stderr.is_empty(), "{host}: {command:?}");
            if denied {
                assert!(!output.stdout.is_empty(), "{host}: {command:?}");
                assert_eq!(
                    native(&output)["hookSpecificOutput"]["permissionDecision"],
                    "deny",
                    "{host}: {command:?}"
                );
            } else {
                assert!(output.stdout.is_empty(), "{host}: {command:?}");
            }
        }
    }
}

#[test]
fn native_hooks_preserve_line_continuation_semantics() {
    for host in ["claude", "codex"] {
        for command in [
            "rm -rf \\\n/etc",
            "rm -rf /e\\\ntc",
            "rm -rf \\\n/",
            "rm \\\n-rf \\\n/etc",
            "git checkout \\\n.",
            "git clean \\\n-fd",
            "rm -rf \\\n  /etc",
            "rm -r\\\nf /etc",
            "r\\\nm -rf /etc",
            "git cle\\\nan -fd",
            "# note \\\ngit clean -fd",
            "echo note\\\\\ngit clean -fd",
            "echo 名前; rm -rf /e\\\ntc",
            "cat <<EOF\\\n; git clean -fd\nbody\nEOF",
            "cat <<'EOF' \\\n; git checkout .\nbody\nEOF",
            "cat <<'EOF' 'note\\\n'; git clean -fd\nbody\nEOF",
            "cat <<-EOF \\\n; rm -rf /e\\\ntc\n\tbody\n\tEOF",
            "cat <<A <<B\\\n; git clean -fd\nbody\nA\nmore\nB",
            "cat <<EO\\\nF; git clean -fd\nbody\nEOF",
            "cat <<'EOF'\nbody\\\nEOF\ngit clean -fd",
            "cat <<'EOF'\n\" \\\nEOF\ngit clean -fd",
            "cat <<EOF\nEO\\\nF\ngit clean -fd",
            "cat <<-EOF\n\tEO\\\nF\ngit checkout .",
            "cat <<A <<'B'\nA\\\n\nbody\nB\ngit clean -fd",
            "rm -rf \"$HO\\\nME\"",
            "rm -rf \"${HO\\\nME}\"",
            "rm -rf \"$\\\nHOME\"",
        ] {
            let denied = invoke(
                &["hook", host],
                &payload("PreToolUse", command).to_string(),
                None,
            );
            success(&denied);
            assert!(!denied.stdout.is_empty(), "{host}: {command:?}");
            assert_eq!(
                native(&denied)["hookSpecificOutput"]["permissionDecision"],
                "deny",
                "{host}: {command:?}"
            );
        }
        for command in [
            "echo note\\; git clean -fd",
            "rm -rf 'note\\\n/etc'",
            "rm -rf \"note\\\n/etc\"",
            "echo ok\\\nrm -rf /",
            "echo ok \\\nrm -rf /",
            "echo 'git clean \\\n-fd'",
            "echo \"rm -rf \\\n/etc\"",
            "# note \\\ngit clean -nfd",
            "echo note\\\\\\\ngit clean -fd",
            "cat <<'EOF'\nrm -rf \\\n/etc\nEOF",
            "cat <<'EOF' \\\n\nrm -rf /etc\nEOF",
            "cat <<'EOF' \\\n # note; git clean -fd\nbody\nEOF",
            "cat <<'EOF' \\\n && printf '%s' 'git clean -fd'\nbody\nEOF",
            "cat <<EOF \\\\\ngit clean -fd\nEOF",
            "cat <<'EOF'\nEO\\\nF\ngit clean -fd",
            "cat <<\"EOF\"\nEO\\\nF\ngit clean -fd",
            "cat <<EOF\nbody\\\nEOF\ngit clean -fd",
            "cat <<EOF\nEO\\\\\nF\ngit clean -fd",
            "cat <<-EOF\nEO\\\n\tF\ngit clean -fd",
            "rm -rf '$HO\\\nME'",
            "rm -rf \"\\$HO\\\nME\"",
        ] {
            let allowed = invoke(
                &["hook", host],
                &payload("PreToolUse", command).to_string(),
                None,
            );
            success(&allowed);
            assert!(allowed.stdout.is_empty(), "{host}: {command:?}");
        }
    }
}

#[test]
fn native_hooks_accept_large_continued_headers() {
    let command = format!("{}echo ok", "\\\n".repeat(100_000));
    for host in ["claude", "codex"] {
        let allowed = invoke(
            &["hook", host],
            &payload("PreToolUse", &command).to_string(),
            None,
        );
        success(&allowed);
        assert!(allowed.stdout.is_empty(), "{host}");
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
        let summary = String::from_utf8_lossy(&status.stderr);
        assert!(summary.contains("codex setup incomplete"), "{summary}");
        assert!(summary.contains("install codex --home"), "{summary}");
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "[features]\nhooks = false\n"
        );
        success(&invoke(&["install", "codex", "--home", home], "", None));
        let enabled = fs::read_to_string(&path).unwrap();
        fs::remove_file(&path).unwrap();
        // Current Codex defaults to enabled when the feature key is absent.
        success(&invoke(&["status", "codex", "--home", home], "", None));
        if original.is_empty() {
            let hooks_path = host_dir.join("hooks.json");
            let mut hooks: Value = serde_json::from_slice(&fs::read(&hooks_path).unwrap()).unwrap();
            hooks["disableAllHooks"] = json!(true);
            fs::write(&hooks_path, serde_json::to_vec(&hooks).unwrap()).unwrap();
            let status = invoke(&["status", "codex", "--home", home], "", None);
            assert_eq!(status.status.code(), Some(1));
            let summary = String::from_utf8_lossy(&status.stderr);
            assert!(summary.contains("review disableAllHooks"), "{summary}");
            assert!(!summary.contains("install codex"), "{summary}");
        }
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
fn forced_cleanup_denial_explains_the_authorization_limit() {
    // These are proposed commands on stdin, never commands executed by this test.
    for host in ["claude", "codex", "grok", "dsh"] {
        for command in ["git clean -fd", "git clean -fd -- scratch.txt"] {
            let output = invoke(
                &["hook", host],
                &payload("PreToolUse", command).to_string(),
                None,
            );
            success(&output);
            assert!(output.stderr.is_empty());
            let response = native(&output);
            let decision = &response["hookSpecificOutput"];
            assert_eq!(decision["hookEventName"], "PreToolUse");
            assert_eq!(decision["permissionDecision"], "deny");
            assert!(decision.get("updatedInput").is_none());
            let reason = decision["permissionDecisionReason"].as_str().unwrap();
            assert!(reason.contains("including explicit paths"));
            assert!(reason.contains("cannot determine task-level authorization"));
            assert!(!reason.contains("select the files to remove"));
        }
        let dry_run = invoke(
            &["hook", host],
            &payload("PreToolUse", "git clean -nfd -- scratch.txt").to_string(),
            None,
        );
        success(&dry_run);
        assert!(dry_run.stdout.is_empty());
        assert!(dry_run.stderr.is_empty());
    }
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
            ("rm -r -f /", true),
            ("rm -f -r /", true),
            ("rm -r --force /", true),
            ("rm --recursive -f /", true),
            ("sudo rm -r -f /", true),
            ("sudo rm -rf /etc/../root", true),
            ("rm -rf /root", true),
            ("rm -rf /root/cache/..", true),
            ("rm -rf '/tmp/../root/.'", true),
            ("rm -rf /.", true),
            ("rm -rf /..", true),
            ("rm -rf //", true),
            ("rm -rf ///", true),
            ("rm -rf /./", true),
            ("rm -rf /home/user/..", true),
            ("rm -rf /Users/foo/..", true),
            ("rm -rf \"$HOME/..\"", true),
            ("rm -rf ~/..", true),
            ("rm -rf /tmp/../etc", true),
            ("rm -rf /private/etc", cfg!(target_os = "macos")),
            ("rm -rf /private/var", cfg!(target_os = "macos")),
            ("rm -rf \"$HOME/cache/..\"", true),
            ("rm -rf \"$HOME/../../etc\"", true),
            ("rm -rf ~/../../etc", true),
            ("rm -rf \"${HOME}/cache/../../../var/log\"", true),
            ("rm -rf ~/../sibling", true),
            ("sudo rm -rf ~root", true),
            ("rm -rf ~root>/tmp/log", true),
            ("rm -rf ~root/.", true),
            ("rm -rf ~root/cache/..", true),
            ("rm -rf ~root/../etc", true),
            ("rm -r \\\n-f ~root", true),
            ("rm -rf \"$HOME/../../e\\\ntc\"", true),
            ("rm -r -f -- /", true),
            ("rm -r /", false),
            ("rm -f /", false),
            ("rm -- -rf /", false),
            ("rm -rf '$HOME/..'", false),
            ("rm -rf '~/..'", false),
            ("rm -rf \"$HOME/cache\"", false),
            ("rm -r -f ./build", false),
            ("rm -rf /etc/../tmp/build", false),
            ("rm -rf /root/cache", false),
            ("rm -rf /root/../tmp/build", false),
            ("rm -rf /rooted", false),
            ("rm -rf ~root/cache", false),
            ("rm -rf '~root'", false),
            ("rm -rf \"~root\"", false),
            ("rm -rf '~root/..'", false),
            (r"rm -rf \~root", false),
            ("rm -rf ~rooted", false),
            ("rm -rf '~/../../etc'", false),
            ("rm -rf '$HOME/../../etc'", false),
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
fn status_coverage_is_potential_until_setup_is_complete() {
    use std::os::unix::fs::PermissionsExt;

    for host in ["claude", "codex", "grok"] {
        for state in [
            "fresh",
            "uninstalled",
            "disabled",
            "feature_disabled",
            "binary_missing",
            "binary_not_executable",
            "ready",
        ] {
            if state == "feature_disabled" && host != "codex" {
                continue;
            }
            let temp = Temp::new();
            let home = temp.0.to_str().unwrap();
            if state != "fresh" {
                success(&invoke(&["install", host, "--home", home], "", None));
            }
            let binary = temp.0.join(".vibeguard/bin/vibeguard-runtime");
            match state {
                "uninstalled" => {
                    success(&invoke(&["uninstall", host, "--home", home], "", None));
                }
                "disabled" => {
                    let config_path = temp.0.join(match host {
                        "claude" => ".claude/settings.json",
                        "codex" => ".codex/hooks.json",
                        _ => ".grok/hooks/vibeguard.json",
                    });
                    let mut config: Value =
                        serde_json::from_slice(&fs::read(&config_path).unwrap()).unwrap();
                    config["disableAllHooks"] = json!(true);
                    fs::write(config_path, config.to_string()).unwrap();
                }
                "feature_disabled" => {
                    fs::write(
                        temp.0.join(".codex/config.toml"),
                        "[features]\nhooks = false\n",
                    )
                    .unwrap();
                }
                "binary_missing" => fs::remove_file(&binary).unwrap(),
                "binary_not_executable" => {
                    fs::set_permissions(&binary, fs::Permissions::from_mode(0o600)).unwrap();
                }
                _ => {}
            }
            let before = snapshot(&temp.0);
            let output = invoke(&["status", host, "--home", home], "", None);
            let ready = state == "ready";
            assert_eq!(
                output.status.code(),
                Some(i32::from(!ready)),
                "{host}/{state}"
            );
            assert_eq!(snapshot(&temp.0), before, "{host}/{state}");
            let status = native(&output);
            assert_eq!(
                status["configured"],
                !matches!(state, "fresh" | "uninstalled")
            );
            assert_eq!(
                status["binary_executable"],
                !matches!(state, "fresh" | "binary_missing" | "binary_not_executable")
            );
            let tool = if host == "grok" {
                "run_terminal_command"
            } else {
                "Bash"
            };
            let coverage = format!(
                "registered {tool} events only; not a sandbox or task-verification certificate"
            );
            assert_eq!(status["coverage"], coverage);
            assert_eq!(status["host_trust"], "not_observed");
            let summary = String::from_utf8_lossy(&output.stderr);
            let prefix = if ready {
                "Coverage"
            } else {
                "Potential coverage once setup is complete"
            };
            assert!(
                summary
                    .lines()
                    .any(|line| line == format!("{prefix}: {coverage}")),
                "{host}/{state}: {summary}"
            );
            assert_eq!(
                summary.lines().any(|line| line.starts_with("Coverage:")),
                ready
            );
            let first_line = summary.lines().next().unwrap();
            if state == "disabled" {
                assert!(first_line.contains("review disableAllHooks"));
            } else if !ready {
                assert!(first_line.contains(&format!("install {host} --home")));
            }
            assert!(summary.contains("No observation recorded."));
        }
    }
}

#[cfg(unix)]
#[test]
fn status_observations_are_read_only_diagnostics_not_protection_claims() {
    for host in ["claude", "codex", "grok"] {
        let temp = Temp::new();
        let home = temp.0.to_str().unwrap();
        let args = ["status", host, "--home", home];
        let before = snapshot(&temp.0);
        let missing = invoke(&args, "", None);
        assert_eq!(missing.status.code(), Some(1));
        assert!(String::from_utf8_lossy(&missing.stderr).contains("No observation recorded."));
        assert_eq!(snapshot(&temp.0), before);

        success(&invoke(&["install", host, "--home", home], "", None));
        let before = snapshot(&temp.0);
        let empty = invoke(&args, "", None);
        success(&empty);
        let baseline = native(&empty);
        assert_eq!(baseline["last_observation"], Value::Null);
        assert!(String::from_utf8_lossy(&empty.stderr).contains("No observation recorded."));
        assert_eq!(snapshot(&temp.0), before);

        let state = temp.0.join(".vibeguard/state");
        fs::create_dir_all(&state).unwrap();
        let tool = if host == "grok" {
            "run_terminal_command"
        } else {
            "Bash"
        };
        // Synthetic records exercise the display contract, not live host trust or dispatch.
        for (event, outcome, code) in [
            ("PreToolUse", "denied", None),
            ("PostToolUse", "running", None),
            ("PostToolUse", "exit_status_unavailable", None),
            ("PostToolUse", "exited_zero", Some(0)),
            ("PostToolUse", "exited_nonzero", Some(7)),
        ] {
            let record = json!({
                "observed_at_unix_ms": 1, "host": host, "event": event, "tool": tool,
                "cwd": "/other/project\n\u{1b}[2J", "outcome": outcome, "exit_code": code,
                "tool_use_id": "fixture"
            });
            fs::write(state.join(format!("{host}.json")), record.to_string()).unwrap();
            let before = snapshot(&temp.0);
            let output = invoke(&args, "", None);
            success(&output);
            assert_eq!(snapshot(&temp.0), before);
            let mut expected = baseline.clone();
            expected["last_observation"] = record;
            assert_eq!(native(&output), expected);
            let summary = String::from_utf8_lossy(&output.stderr);
            for text in [
                format!("{host} setup complete; host trust remains unobserved"),
                format!("Coverage: {}", baseline["coverage"].as_str().unwrap()),
                "Latest received event (across sessions; may be old or from another cwd)".into(),
                "time (Unix ms)=1".into(),
                "cwd=\"/other/project\\n\\u001b[2J\"".into(),
                format!("tool=\"{tool}\""),
                format!("event=\"{event}\""),
                format!("outcome=\"{outcome}\""),
                format!("exit_code={}", code.map_or("unavailable".into(), |c| c.to_string())),
                "Observations do not prove host trust, actual execution, full protection, or task completion for the current project.".into(),
            ] {
                assert!(summary.contains(&text), "missing {text:?}: {summary}");
            }
            assert!(!summary.contains('\u{1b}'));
            assert!(!summary.contains("No observation recorded."));
        }

        let config_path = temp.0.join(match host {
            "claude" => ".claude/settings.json",
            "codex" => ".codex/hooks.json",
            _ => ".grok/hooks/vibeguard.json",
        });
        let mut config: Value = serde_json::from_slice(&fs::read(&config_path).unwrap()).unwrap();
        config["disableAllHooks"] = json!(true);
        fs::write(&config_path, config.to_string()).unwrap();
        let before = snapshot(&temp.0);
        let disabled = invoke(&args, "", None);
        assert_eq!(disabled.status.code(), Some(1));
        let summary = String::from_utf8_lossy(&disabled.stderr);
        assert!(
            summary
                .lines()
                .next()
                .unwrap()
                .contains("review disableAllHooks")
        );
        assert!(summary.contains("Latest received event"));
        assert!(!summary.contains("setup complete"));
        assert_eq!(snapshot(&temp.0), before);

        let instructions = temp.0.join(".claude/CLAUDE.md");
        fs::create_dir_all(instructions.parent().unwrap()).unwrap();
        fs::write(
            &instructions,
            "<!-- vibeguard-start -->\nold\n<!-- vibeguard-end -->\n",
        )
        .unwrap();
        let before = snapshot(&temp.0);
        let legacy = invoke(&args, "", None);
        assert_eq!(legacy.status.code(), Some(1));
        let summary = String::from_utf8_lossy(&legacy.stderr);
        assert!(
            summary
                .lines()
                .next()
                .unwrap()
                .contains("known v1 remnants")
        );
        assert!(
            summary
                .lines()
                .next()
                .unwrap()
                .contains("review legacy.findings")
        );
        assert!(summary.contains("Latest received event"));
        assert_eq!(snapshot(&temp.0), before);
    }
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
        assert_eq!(first_instructions, user_text.as_bytes());
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
fn installation_and_status_do_not_require_instruction_files() {
    for host in ["claude", "codex"] {
        let temp = Temp::new();
        let home = temp.0.to_str().unwrap();
        let instructions = temp.0.join(format!(".{host}")).join(if host == "codex" {
            "AGENTS.md"
        } else {
            "CLAUDE.md"
        });
        success(&invoke(&["install", host, "--home", home], "", None));
        assert!(!instructions.exists());
        let state = invoke(&["status", host, "--home", home], "", None);
        success(&state);
        assert!(native(&state).get("core_present").is_none());
        for text in [
            "User-owned instructions\r\nNo final newline",
            "<!-- vibeguard-core:start -->\nEdited core\n<!-- vibeguard-core:end -->\n",
            "<!-- vibeguard-core:start -->\nincomplete",
        ] {
            fs::write(&instructions, text).unwrap();
            let state = invoke(&["status", host, "--home", home], "", None);
            success(&state);
            assert!(native(&state).get("core_present").is_none());
            assert_eq!(fs::read_to_string(&instructions).unwrap(), text);
        }
        fs::remove_file(&instructions).unwrap();
        for action in ["install", "uninstall", "uninstall"] {
            success(&invoke(&[action, host, "--home", home], "", None));
            assert!(!instructions.exists());
        }
    }
}

#[cfg(unix)]
#[test]
fn install_and_uninstall_remove_only_the_owned_core_block() {
    for host in ["claude", "codex"] {
        let temp = Temp::new();
        let home = temp.0.to_str().unwrap();
        let host_dir = temp.0.join(format!(".{host}"));
        fs::create_dir(&host_dir).unwrap();
        let instructions = host_dir.join(if host == "codex" {
            "AGENTS.md"
        } else {
            "CLAUDE.md"
        });
        let prefix = "用户自己的指令\r\n";
        let suffix = "User-owned suffix without final newline";
        for action in ["install", "uninstall"] {
            for owned in [
                "<!-- vibeguard-core:start -->\nPrevious core\n<!-- vibeguard-core:end -->\n",
                "<!-- vibeguard-core:start -->\r\nEdited core\r\n<!-- vibeguard-core:end -->\r\n",
            ] {
                fs::write(&instructions, format!("{prefix}{owned}{suffix}")).unwrap();
                success(&invoke(&[action, host, "--home", home], "", None));
                assert_eq!(
                    fs::read_to_string(&instructions).unwrap(),
                    format!("{prefix}{suffix}")
                );
                success(&invoke(&[action, host, "--home", home], "", None));
                assert_eq!(
                    fs::read_to_string(&instructions).unwrap(),
                    format!("{prefix}{suffix}")
                );
            }
        }
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
    let user_status = invoke(
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
    );
    assert_eq!(user_status.status.code(), Some(1));
    assert_eq!(native(&user_status)["user_managed_hook"], true);
    let summary = String::from_utf8_lossy(&user_status.stderr);
    assert!(
        summary.contains("pre-push hook is user-managed"),
        "{summary}"
    );
    assert!(!summary.contains("install git"), "{summary}");
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
    let status = invoke(&status_args, "", None);
    assert_eq!(status.status.code(), Some(1));
    let summary = String::from_utf8_lossy(&status.stderr);
    assert!(summary.contains("git setup incomplete"), "{summary}");
    assert!(summary.contains("install git --home"), "{summary}");
    assert!(summary.contains("--repo"), "{summary}");
    success(&invoke(&args, "", None));
    assert_ne!(fs::metadata(&hook).unwrap().permissions().mode() & 0o111, 0);
    let healthy = invoke(
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
    );
    success(&healthy);
    let summary = String::from_utf8_lossy(&healthy.stderr);
    assert!(summary.contains("git setup complete"), "{summary}");
    assert!(
        summary.contains("pre-push execution is unobserved"),
        "{summary}"
    );
    assert!(!summary.contains("Bash command"), "{summary}");
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

#[cfg(windows)]
#[test]
fn windows_short_paths_use_actual_long_names() {
    use std::os::windows::ffi::OsStrExt;
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetShortPathNameW(path: *const u16, output: *mut u16, size: u32) -> u32;
    }
    let short_path = |path: &Path| {
        let input: Vec<_> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        let mut output = vec![0u16; 32768];
        // SAFETY: input is NUL-terminated and output has the declared capacity.
        let length =
            unsafe { GetShortPathNameW(input.as_ptr(), output.as_mut_ptr(), output.len() as u32) };
        assert!(length > 0 && (length as usize) < output.len());
        let short = String::from_utf16(&output[..length as usize]).unwrap();
        assert_ne!(
            short.to_ascii_lowercase(),
            path.to_string_lossy().to_ascii_lowercase(),
            "Windows test volume must provide an actual 8.3 alias"
        );
        short
    };
    let system = PathBuf::from(std::env::var_os("ProgramFiles").unwrap());
    let system_alias = short_path(&system).replace('\\', "/");
    let temp = Temp::new();
    let safe = temp.0.join("safe long directory");
    fs::create_dir(&safe).unwrap();
    let safe_alias = short_path(&safe).replace('\\', "/");
    for (path, blocked) in [
        (system_alias.clone(), true),
        (
            format!("/{}{}", &system_alias[..1], &system_alias[2..]),
            true,
        ),
        (format!("{system_alias}/absent-child"), true),
        (safe_alias.clone(), false),
        (format!("{safe_alias}/absent-child"), false),
    ] {
        let output = invoke(
            &["hook", "claude"],
            &payload("PreToolUse", &format!("rm -rf '{path}'")).to_string(),
            None,
        );
        success(&output);
        let denied = !output.stdout.is_empty();
        assert_eq!(denied, blocked, "{path}");
        if denied {
            assert_eq!(
                native(&output)["hookSpecificOutput"]["permissionDecision"],
                "deny"
            );
        }
    }
    assert!(
        system.is_dir() && safe.is_dir(),
        "hook input must never execute rm"
    );
}

#[cfg(windows)]
#[test]
fn windows_replacement_preserves_explicit_dacl_and_reports_locked_targets() {
    let temp = Temp::new();
    let script = r#"
$ErrorActionPreference = 'Stop'
$binary = $env:VIBEGUARD_TEST_BINARY
$home_path = $env:VIBEGUARD_TEST_HOME
$config = Join-Path $home_path '.claude/settings.json'
$instructions = Join-Path $home_path '.claude/CLAUDE.md'
$installed = Join-Path $home_path '.vibeguard/bin/vibeguard-runtime.exe'
New-Item -ItemType Directory -Path (Split-Path $config), (Split-Path $installed) | Out-Null
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
foreach ($path in @($config, $instructions, $installed)) {
    [IO.File]::WriteAllText($path, '')
    $acl = Get-Acl -LiteralPath $path
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
    Set-Acl -LiteralPath $path -AclObject $acl
}
$expected = @{}
foreach ($path in @($config, $instructions, $installed)) { $expected[$path] = (Get-Acl -LiteralPath $path).Sddl }
foreach ($phase in @('install', 'reinstall', 'uninstall')) {
    if ($phase -ne 'uninstall') {
        [IO.File]::WriteAllText($config, '{}')
        [IO.File]::WriteAllText($installed, 'old binary fixture')
    }
    [IO.File]::WriteAllText($instructions, "user note`n<!-- vibeguard-core:start -->`nowned`n<!-- vibeguard-core:end -->`n")
    $action = if ($phase -eq 'uninstall') { 'uninstall' } else { 'install' }
    & $binary $action claude --home $home_path
    if ($LASTEXITCODE -ne 0) { throw "$phase failed" }
    foreach ($path in @($config, $instructions, $installed)) {
        if ((Get-Acl -LiteralPath $path).Sddl -ne $expected[$path]) { throw "$phase changed explicit DACL: $path" }
    }
    if ([IO.File]::ReadAllText($instructions) -ne "user note`n") { throw 'Owned block removal failed' }
    if ((Get-FileHash -LiteralPath $installed).Hash -ne (Get-FileHash -LiteralPath $binary).Hash) { throw 'Binary replacement failed' }
}
[IO.File]::WriteAllText($config, '{}')
$locked = [IO.File]::Open($config, 'Open', 'Read', 'Read')
try {
    $ErrorActionPreference = 'Continue'
    $output = & $binary install claude --home $home_path 2>&1
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 2) { throw 'Locked-target replacement did not preserve exit 2' }
    if ([string]::IsNullOrWhiteSpace(($output | Out-String))) { throw 'Replacement error was hidden' }
} finally { $locked.Dispose() }
if ([IO.File]::ReadAllText($config) -ne '{}') { throw 'Locked target bytes changed' }
if ((Get-Acl -LiteralPath $config).Sddl -ne $expected[$config]) { throw 'Locked target DACL changed' }
if (Get-ChildItem -LiteralPath (Split-Path $config) -Force -Filter '*.tmp') { throw 'Staged replacement leaked' }
"#;
    let output = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .env("VIBEGUARD_TEST_BINARY", BIN)
        .env("VIBEGUARD_TEST_HOME", &temp.0)
        .output()
        .unwrap();
    success(&output);
}

#[cfg(windows)]
#[test]
fn windows_status_next_actions_execute_in_powershell() {
    let temp = Temp::new();
    let home = temp.0.join("用户 space ' $ home");
    let args = ["status", "claude", "--home", home.to_str().unwrap()];
    let incomplete = invoke(&args, "", None);
    assert_eq!(incomplete.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&incomplete.stderr);
    let install = stderr
        .lines()
        .find_map(|line| line.split_once("Next: run "))
        .unwrap()
        .1
        .strip_suffix('.')
        .unwrap();
    let installed = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", install])
        .output()
        .unwrap();
    success(&installed);
    assert!(home.join(".vibeguard/bin/vibeguard-runtime.exe").is_file());
    let ready = invoke(&args, "", None);
    success(&ready);
    let stderr = String::from_utf8_lossy(&ready.stderr);
    let status = stderr
        .split_once("then rerun ")
        .unwrap()
        .1
        .split_once(" and inspect last_observation.")
        .unwrap()
        .0;
    success(
        &Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command", status])
            .output()
            .unwrap(),
    );
}

#[cfg(windows)]
#[test]
fn windows_claude_installation_uses_exec_and_preserves_user_handlers() {
    let temp = Temp::new();
    let home = temp.0.join("用户 space ' $ home");
    let args = ["install", "claude", "--home", home.to_str().unwrap()];
    let preview = invoke(&[args.as_slice(), &["--dry-run"]].concat(), "", None);
    success(&preview);
    assert!(!home.exists());
    assert!(native(&preview)["details"]["hook_args"].is_array());
    fs::create_dir_all(home.join(".claude")).unwrap();
    let config_path = home.join(".claude/settings.json");
    fs::write(&config_path, r#"{"user":7,"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo user"}]}]}}"#).unwrap();
    fs::write(home.join(".claude/CLAUDE.md"), "user text\r\n").unwrap();
    let installed = invoke(&args, "", None);
    success(&installed);
    assert_eq!(native(&installed)["legacy"]["findings"], json!([]));
    let config: Value = serde_json::from_slice(&fs::read(&config_path).unwrap()).unwrap();
    let handler = &config["hooks"]["PreToolUse"][1]["hooks"][0];
    assert_eq!(handler["args"][0], "hook");
    assert!(handler["command"].as_str().unwrap().ends_with(".exe"));
    let mut child = Command::new(handler["command"].as_str().unwrap())
        .args(
            handler["args"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_str().unwrap()),
        )
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
            payload("PreToolUse", "rm -rf /c/Windows")
                .to_string()
                .as_bytes(),
        )
        .unwrap();
    let result = child.wait_with_output().unwrap();
    success(&result);
    assert_eq!(
        native(&result)["hookSpecificOutput"]["permissionDecision"],
        "deny"
    );
    let status = invoke(
        &["status", "claude", "--home", home.to_str().unwrap()],
        "",
        None,
    );
    success(&status);
    assert_eq!(native(&status)["legacy"]["findings"], json!([]));
    let summary = String::from_utf8_lossy(&status.stderr);
    assert!(summary.contains("then rerun & '"), "{summary}");
    assert!(summary.contains("space '' $ home'"), "{summary}");
    assert_eq!(native(&status)["last_observation"]["outcome"], "denied");
    assert!(
        native(&status)["coverage"]
            .as_str()
            .unwrap()
            .contains("PowerShell and cmd commands are not protected")
    );
    // Reinstall from the installed executable as users do, then from the source binary.
    success(
        &Command::new(handler["command"].as_str().unwrap())
            .args(args)
            .output()
            .unwrap(),
    );
    success(&invoke(&args, "", None));
    let after: Value = serde_json::from_slice(&fs::read(&config_path).unwrap()).unwrap();
    assert_eq!(config, after);
    success(&invoke(
        &["uninstall", "claude", "--home", home.to_str().unwrap()],
        "",
        None,
    ));
    let after: Value = serde_json::from_slice(&fs::read(&config_path).unwrap()).unwrap();
    assert_eq!(after["user"], 7);
    assert_eq!(
        after["hooks"]["PreToolUse"][0]["hooks"][0]["command"],
        "echo user"
    );
    assert_eq!(
        fs::read(home.join(".claude/CLAUDE.md")).unwrap(),
        b"user text\r\n"
    );
    assert!(!home.join(".vibeguard/state/claude.json").exists());
}

#[cfg(windows)]
#[test]
fn windows_home_falls_back_to_userprofile_and_bad_json_fails_before_writes() {
    let temp = Temp::new();
    for empty_home in [false, true] {
        let home = temp
            .0
            .join(if empty_home { "empty home" } else { "no home" });
        let mut command = Command::new(BIN);
        command
            .env_remove("HOME")
            .env("USERPROFILE", &home)
            .env_remove("CLAUDE_CONFIG_DIR");
        if empty_home {
            command.env("HOME", "");
        }
        let output = command
            .args(["install", "claude", "--dry-run"])
            .output()
            .unwrap();
        success(&output);
        assert!(!home.exists());
        assert!(
            native(&output)["details"]["hook_command"]
                .as_str()
                .unwrap()
                .starts_with(home.to_str().unwrap())
        );
    }
    fs::create_dir_all(temp.0.join(".claude")).unwrap();
    fs::write(temp.0.join(".claude/settings.json"), "invalid JSON").unwrap();
    let output = invoke(
        &["install", "claude", "--home", temp.0.to_str().unwrap()],
        "",
        None,
    );
    assert_eq!(output.status.code(), Some(2));
    assert!(!temp.0.join(".vibeguard").exists());
}
