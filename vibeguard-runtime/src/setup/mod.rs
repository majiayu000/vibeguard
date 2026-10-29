mod legacy;
mod markdown;
pub mod support;

use crate::{Result, logging, print_json};
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use support::{
    check_unchanged, executable, lock_setup, make_executable, read_optional, read_text,
    shell_quote, write_atomic, write_atomic_if_unchanged,
};

struct Options {
    host: String,
    home: PathBuf,
    explicit_home: bool,
    host_dir: PathBuf,
    claude_dir: PathBuf,
    codex_dir: PathBuf,
    gemini_dir: PathBuf,
    repo: PathBuf,
    inspect_repo: bool,
    dry_run: bool,
    migrate_v1_hooks: bool,
}

impl Options {
    fn parse(args: &[String]) -> Result<Self> {
        let host = args
            .first()
            .filter(|v| matches!(v.as_str(), "claude" | "codex" | "grok" | "git"))
            .ok_or("target must be claude, codex, grok or git")?
            .clone();
        let mut explicit_home = None;
        let mut repo = None;
        let mut dry_run = false;
        let mut migrate_v1_hooks = false;
        let mut rest = args[1..].iter();
        while let Some(flag) = rest.next() {
            if flag == "--migrate-v1-hooks" && !migrate_v1_hooks {
                migrate_v1_hooks = true;
                continue;
            }
            if flag == "--dry-run" && !dry_run {
                dry_run = true;
                continue;
            }
            let value = rest.next().ok_or("option requires a path")?;
            match flag.as_str() {
                "--home" if explicit_home.is_none() => explicit_home = Some(PathBuf::from(value)),
                "--repo" if repo.is_none() => repo = Some(PathBuf::from(value)),
                _ => return Err("unknown or repeated installation option".into()),
            }
        }
        let is_explicit = explicit_home.is_some();
        let inspect_repo = host == "git" || repo.is_some();
        let home = explicit_home
            .or_else(|| {
                std::env::var_os("HOME")
                    .filter(|p| !p.is_empty())
                    .or_else(|| cfg!(windows).then(|| std::env::var_os("USERPROFILE")).flatten())
                    .map(PathBuf::from)
            })
            .filter(|p| !p.as_os_str().is_empty())
            .ok_or("user home is unavailable; set HOME (or USERPROFILE on Windows), or pass --home PATH")?;
        let home = absolute(home)?;
        // An explicit --home is an isolated installation. Ambient host directories
        // belong to the account, not to that home.
        let claude_dir = if is_explicit {
            None
        } else {
            std::env::var_os("CLAUDE_CONFIG_DIR")
                .filter(|p| !p.is_empty())
                .map(PathBuf::from)
                .map(absolute)
                .transpose()?
        }
        .unwrap_or_else(|| home.join(".claude"));
        let codex_dir = if is_explicit {
            None
        } else {
            std::env::var_os("CODEX_HOME")
                .filter(|p| !p.is_empty())
                .map(PathBuf::from)
                .map(absolute)
                .transpose()?
        }
        .unwrap_or_else(|| home.join(".codex"));
        let gemini_dir = if is_explicit {
            None
        } else {
            std::env::var_os("GEMINI_CLI_HOME")
                .filter(|p| !p.is_empty())
                .map(PathBuf::from)
                .map(absolute)
                .transpose()?
        }
        .unwrap_or_else(|| home.clone())
        .join(".gemini");
        let host_dir = if host == "claude" {
            claude_dir.clone()
        } else if host == "codex" {
            codex_dir.clone()
        } else if host == "grok" && !is_explicit {
            std::env::var_os("GROK_HOME")
                .filter(|p| !p.is_empty())
                .map(PathBuf::from)
                .map(absolute)
                .transpose()?
                .unwrap_or_else(|| home.join(".grok"))
        } else {
            home.join(format!(".{host}"))
        };
        quote_path(&host_dir)?;
        Ok(Self {
            host,
            home,
            explicit_home: is_explicit,
            host_dir,
            claude_dir,
            codex_dir,
            gemini_dir,
            repo: absolute(repo.unwrap_or(std::env::current_dir()?))?,
            inspect_repo,
            dry_run,
            migrate_v1_hooks,
        })
    }
    fn binary(&self) -> PathBuf {
        self.home.join(".vibeguard/bin").join(if cfg!(windows) {
            "vibeguard-runtime.exe"
        } else {
            "vibeguard-runtime"
        })
    }
    fn state(&self) -> PathBuf {
        self.home.join(".vibeguard/state")
    }
    fn config(&self) -> PathBuf {
        self.host_dir.join(match self.host.as_str() {
            "codex" => "hooks.json",
            "grok" => "hooks/vibeguard.json",
            _ => "settings.json",
        })
    }
    fn instructions(&self) -> PathBuf {
        self.host_dir.join(match self.host.as_str() {
            "codex" => "AGENTS.md",
            "grok" => "rules/vibeguard.md",
            _ => "CLAUDE.md",
        })
    }
    fn command(&self) -> Result<String> {
        if cfg!(windows) && self.host == "claude" {
            return Ok(self
                .binary()
                .to_str()
                .ok_or("installation paths must be valid UTF-8")?
                .into());
        }
        Ok(format!(
            "{} hook {} --state-dir {}",
            quote_path(&self.binary())?,
            self.host,
            quote_path(&self.state())?
        ))
    }
    fn handler(&self) -> Result<Value> {
        let mut handler = json!({"type":"command","command":self.command()?,"timeout":10});
        if cfg!(windows) && self.host == "claude" {
            handler["args"] = json!(["hook", "claude", "--state-dir", self.state()]);
        }
        Ok(handler)
    }
}

fn absolute(path: PathBuf) -> Result<PathBuf> {
    if path.is_absolute() {
        Ok(path)
    } else {
        Ok(std::env::current_dir()?.join(path))
    }
}

fn quote_path(path: &Path) -> Result<String> {
    let value = path
        .to_str()
        .ok_or("installation paths must be valid UTF-8")?;
    if value.contains(['\n', '\r', '`']) {
        return Err("installation paths cannot contain newlines or Markdown backticks".into());
    }
    Ok(shell_quote(value))
}

pub fn run(action: &str, args: &[String]) -> Result<u8> {
    let options = Options::parse(args)?;
    if options.migrate_v1_hooks && (action != "install" || options.host != "claude") {
        return Err("--migrate-v1-hooks requires install claude".into());
    }
    if options.dry_run && action != "install" {
        return Err("--dry-run is supported only by install".into());
    }
    if action != "status" && !cfg!(unix) && !(cfg!(windows) && options.host == "claude") {
        return Err("native Windows installation supports Claude Code only; use WSL for other targets; no configuration was changed".into());
    }
    if options.host == "git" {
        return git_integration(action, &options);
    }
    let config_path = options.config();
    let old_config = read_text(&config_path)?;
    let mut config: Value = match &old_config {
        Some(text) => serde_json::from_str(text)
            .map_err(|_| format!("{} contains invalid JSON", config_path.display()))?,
        None => json!({}),
    };
    validate_config(&config)?;
    let original_config = config.clone();
    let feature_path = options.host_dir.join("config.toml");
    let old_features = if options.host == "codex" {
        read_text(&feature_path)?
    } else {
        None
    };
    let feature_doc = if options.host == "codex" {
        Some(
            old_features
                .as_deref()
                .unwrap_or("")
                .parse::<toml_edit::DocumentMut>()
                .map_err(|_| format!("{} contains invalid TOML", feature_path.display()))?,
        )
    } else {
        None
    };
    let feature_enabled = feature_doc.as_ref().map(codex_hooks_enabled).transpose()?;
    let command = options.command()?;
    let handler = options.handler()?;
    let specs = hook_specs(&options.host, &handler);
    if action == "status" {
        let configured = specs.iter().all(|(event, spec)| {
            config
                .get("hooks")
                .and_then(|h| h.get(event))
                .and_then(Value::as_array)
                .is_some_and(|groups| groups.contains(spec))
        });
        let binary_present = read_optional(&options.binary())?.is_some();
        let binary_executable = executable(&options.binary())?;
        let disabled = config.get("disableAllHooks").and_then(Value::as_bool);
        let ready = configured
            && binary_executable
            && disabled != Some(true)
            && feature_enabled != Some(false);
        publish(
            json!({
                "host": options.host, "config": config_path, "configured": configured,
                "installation_home": options.home,
                "binary": options.binary(), "state_dir": options.state(),
                "hook_registrations": hook_registrations(&config, &handler),
                "binary_present": binary_present,
                "binary_executable": binary_executable,
                "host_hooks_feature_enabled": feature_enabled,
                "host_hook_disable_flag": disabled, "host_trust": "not_observed",
                "last_observation": logging::latest(&options.state(), &options.host)?,
                "coverage": if cfg!(windows) && options.host == "claude" {
                    "registered Bash events only (Git Bash); PowerShell and cmd commands are not protected; requires Claude Code 2.1.139 or later; Windows host execution is experimental until verified"
                } else if options.host == "grok" {
                    "registered run_terminal_command events only; not a sandbox or task-verification certificate"
                } else {
                    "registered Bash events only; not a sandbox or task-verification certificate"
                }
            }),
            &options,
            Some(ready),
        )?;
        return Ok(u8::from(!ready));
    }
    let instructions_path = options.instructions();
    let old_instructions = read_text(&instructions_path)?;
    let old_text = old_instructions.as_deref().unwrap_or("");
    let new_instructions = markdown::remove(old_text)?;
    let new_features = if action == "install" {
        feature_doc.map(|mut doc| {
            let features = doc
                .entry("features")
                .or_insert(toml_edit::Item::Table(toml_edit::Table::new()))
                .as_table_like_mut()
                .expect("validated features table");
            let mut enabled = toml_edit::value(true);
            if let Some(previous) = features.get("hooks").and_then(toml_edit::Item::as_value) {
                *enabled.as_value_mut().expect("boolean value").decor_mut() =
                    previous.decor().clone();
            }
            features.insert("hooks", enabled);
            doc.to_string()
        })
    } else {
        None
    };
    // Validate inputs and owned regions before writing any installation files.
    let removed_v1_hooks = if options.migrate_v1_hooks {
        prune_v1_claude_hooks(&mut config)
    } else {
        0
    };
    let migration_backup = if removed_v1_hooks > 0 {
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_nanos();
        Some(
            options
                .host_dir
                .join(format!("settings.json.vibeguard-v1-{timestamp}.bak")),
        )
    } else {
        None
    };
    let removed_skills_loader = prune_hooks(
        &mut config,
        &handler,
        action == "install" && options.host == "claude",
    );
    if action == "install" {
        let hooks = config
            .as_object_mut()
            .expect("validated object")
            .entry("hooks")
            .or_insert(json!({}))
            .as_object_mut()
            .expect("validated hooks object");
        for (event, spec) in specs {
            hooks
                .entry(event)
                .or_insert(json!([]))
                .as_array_mut()
                .expect("validated event array")
                .push(spec);
        }
    }
    let observation = options.state().join(format!("{}.json", options.host));
    let remove_observation = action == "uninstall" && read_optional(&observation)?.is_some();
    let will_write = action == "install"
        || config != original_config
        || new_instructions != old_text
        || remove_observation;
    if options.dry_run {
        let mut changes = binary_changes(&options)?;
        if let Some(backup) = &migration_backup {
            changes.push(json!({"path":backup,"operation":"backup_original_settings"}));
            changes.push(json!({"path":config_path,"operation":"remove_v1_hooks","handler_count":removed_v1_hooks}));
        }
        if removed_skills_loader > 0 {
            changes.push(
                json!({"path":config_path,"operation":"remove_retired_skills_loader_hooks",
                "handler_count":removed_skills_loader}),
            );
        }
        if config != original_config {
            changes.push(json!({"path":config_path,"operation":"register_hooks",
                "events":hook_specs(&options.host, &handler).into_iter().map(|(event, _)| event).collect::<Vec<_>>() }));
        }
        if let Some(text) = &new_features
            && old_features.as_deref() != Some(text)
        {
            changes.push(json!({"path":feature_path,"operation":"enable_hooks_feature"}));
        }
        if new_instructions != old_text {
            changes.push(json!({"path":instructions_path,"operation":"remove_owned_core_block"}));
        }
        return preview(
            &options,
            changes,
            &options.host_dir,
            json!({"hook_command":command,"hook_args":handler.get("args"),"matcher":if options.host == "grok" { "run_terminal_command" } else { "Bash" },
                "host_hook_disable_flag":config.get("disableAllHooks"),
                "observation":"created by a received hook event; installation does not create an observation"}),
        );
    }
    // Prevalidation remains read-only. Lock only after it succeeds, then detect
    // snapshots changed by another setup or a host while we were preparing.
    let locks = if will_write {
        let locks = lock_setup(&options.home, &options.host_dir)?;
        check_unchanged(&config_path, old_config.as_deref().map(str::as_bytes))?;
        if options.host == "codex" {
            check_unchanged(&feature_path, old_features.as_deref().map(str::as_bytes))?;
        }
        if new_instructions != old_text {
            check_unchanged(
                &instructions_path,
                old_instructions.as_deref().map(str::as_bytes),
            )?;
        }
        Some(locks)
    } else {
        None
    };
    if action == "install" {
        if let Some(backup) = &migration_backup {
            write_atomic_if_unchanged(
                backup,
                old_config
                    .as_deref()
                    .ok_or("migration requires existing settings")?
                    .as_bytes(),
                0o600,
                None,
            )?;
        }
        install_binary(&options)?;
    }
    if config != original_config {
        write_atomic_if_unchanged(
            &config_path,
            (serde_json::to_string_pretty(&config)? + "\n").as_bytes(),
            0o600,
            old_config.as_deref().map(str::as_bytes),
        )?;
    }
    if let Some(text) = new_features
        && old_features.as_deref() != Some(&text)
    {
        write_atomic_if_unchanged(
            &feature_path,
            text.as_bytes(),
            0o600,
            old_features.as_deref().map(str::as_bytes),
        )?;
    }
    if new_instructions != old_text {
        // An empty result does not establish that we own the file itself.
        write_atomic_if_unchanged(
            &instructions_path,
            new_instructions.as_bytes(),
            0o600,
            old_instructions.as_deref().map(str::as_bytes),
        )?;
    }
    if remove_observation && read_optional(&observation)?.is_some() {
        fs::remove_file(observation)?;
    }
    drop(locks);
    publish(
        json!({
            "action":action,"host":options.host,"config":config_path,"instructions":instructions_path,
            "binary":options.binary(),
            "removed_v1_hooks":removed_v1_hooks,"migration_backup":migration_backup,
            "note": if action == "install" {
                "Registered. Restart the host and review its hook trust settings; configuration alone does not prove execution."
            } else {
                "Integration removed. The shared binary remains for other hosts and direct CLI use."
            }
        }),
        &options,
        None,
    )?;
    Ok(0)
}

fn publish(mut value: Value, options: &Options, status_ready: Option<bool>) -> Result<()> {
    let legacy = legacy::inventory(options);
    if let Some(ready) = status_ready {
        eprintln!("{}", status_summary(options, ready, &legacy, &value));
        if value["hook_registrations"]
            .as_array()
            .is_some_and(|entries| {
                entries
                    .iter()
                    .any(|entry| entry["selected_instance"] == false)
            })
        {
            eprintln!(
                "Additional command handlers are registered in {}; inspect hook_registrations for their configured commands. This status checks the installation at {}.",
                options.config().display(),
                options.home.display()
            );
        }
        if options.host != "git" {
            eprintln!(
                "{}: {}",
                if ready {
                    "Coverage"
                } else {
                    "Potential coverage once setup is complete"
                },
                value["coverage"].as_str().unwrap_or_default()
            );
            let observation = &value["last_observation"];
            if observation.is_null() {
                eprintln!("No observation recorded.");
            } else {
                // JSON display escapes record text rather than emitting terminal controls.
                let exit_code = observation["exit_code"]
                    .as_i64()
                    .map_or_else(|| "unavailable".into(), |code| code.to_string());
                eprintln!(
                    "Latest received event (across sessions; may be old or from another cwd): time (Unix ms)={}; cwd={}; tool={}; event={}; outcome={}; exit_code={exit_code}.",
                    observation["observed_at_unix_ms"],
                    observation["cwd"],
                    observation["tool"],
                    observation["event"],
                    observation["outcome"]
                );
            }
            eprintln!(
                "Observations do not prove host trust, actual execution, full protection, or task completion for the current project."
            );
        }
    } else if let Some(message) = legacy::attention_message(&legacy) {
        eprintln!("{message}");
    }
    value["legacy"] = legacy;
    print_json(&value)
}

fn status_summary(options: &Options, ready: bool, legacy: &Value, status: &Value) -> String {
    let findings = legacy["findings"].as_array();
    let known_v1 =
        findings.is_some_and(|items| items.iter().any(|item| item["evidence"] == "owned"));
    let possible_v1 =
        findings.is_some_and(|items| items.iter().any(|item| item["evidence"] == "suspected"));
    let setup = if ready { "complete" } else { "incomplete" };
    if known_v1 || possible_v1 {
        let evidence = if known_v1 { "known" } else { "possible" };
        return format!(
            "VibeGuard {} setup {setup}, with {evidence} v1 remnants; their execution is unobserved. Next: review legacy.findings and legacy.migration before choosing the v1 uninstall command.",
            options.host
        );
    }
    if legacy::attention_message(legacy).is_some() {
        return format!(
            "VibeGuard {} setup {setup}; the legacy inventory is incomplete and current host activation is unproven. Next: inspect legacy.findings and legacy.scheduler.",
            options.host
        );
    }
    if ready && options.host == "git" {
        return "VibeGuard git setup complete; actual pre-push execution is unobserved. Next: verify the hook during your next normal push.".into();
    }
    if status["user_managed_hook"] == true {
        return "VibeGuard git setup incomplete; the existing pre-push hook is user-managed. Next: inspect the hook path in the status JSON before deciding how to integrate VibeGuard.".into();
    }
    if status["host_hook_disable_flag"] == true {
        return format!(
            "VibeGuard {} setup incomplete because host hooks are disabled. Next: review disableAllHooks in {} before reinstalling.",
            options.host,
            options.config().display()
        );
    }
    let quote = |value: &str| {
        if cfg!(windows) {
            format!("'{}'", value.replace('\'', "''"))
        } else {
            shell_quote(value)
        }
    };
    let mut command = format!(
        "{}{} {} {}",
        if cfg!(windows) { "& " } else { "" },
        quote(
            &std::env::args()
                .next()
                .unwrap_or_else(|| "vibeguard-runtime".into())
        ),
        if ready { "status" } else { "install" },
        options.host
    );
    if options.explicit_home {
        command.push_str(&format!(
            " --home {}",
            quote(&options.home.to_string_lossy())
        ));
    }
    if options.inspect_repo {
        command.push_str(&format!(
            " --repo {}",
            quote(&options.repo.to_string_lossy())
        ));
    }
    if ready {
        format!(
            "VibeGuard {} setup complete; host trust remains unobserved. Next: run one harmless Bash command through the host, then rerun {command} and inspect last_observation.",
            options.host
        )
    } else {
        format!(
            "VibeGuard {} setup incomplete. Next: run {command}.",
            options.host
        )
    }
}

fn codex_hooks_enabled(doc: &toml_edit::DocumentMut) -> Result<bool> {
    let Some(features) = doc.get("features") else {
        return Ok(true);
    };
    let features = features
        .as_table_like()
        .ok_or("Codex features must be a TOML table")?;
    for key in ["hooks", "codex_hooks"] {
        if features
            .get(key)
            .is_some_and(|value| value.as_bool().is_none())
        {
            return Err(format!("Codex features.{key} must be a boolean").into());
        }
    }
    // The host still accepts codex_hooks; its canonical hooks key takes precedence.
    Ok(features
        .get("hooks")
        .or_else(|| features.get("codex_hooks"))
        .and_then(toml_edit::Item::as_bool)
        .unwrap_or(true))
}

fn validate_config(config: &Value) -> Result<()> {
    if !config.is_object() {
        return Err("host configuration root must be an object".into());
    }
    if let Some(hooks) = config.get("hooks") {
        let hooks = hooks.as_object().ok_or("host hooks must be an object")?;
        for groups in hooks.values() {
            for group in groups
                .as_array()
                .ok_or("hook event entries must be arrays")?
            {
                if !group.is_object() {
                    return Err("hook group must be an object".into());
                }
                let entries = group
                    .get("hooks")
                    .and_then(Value::as_array)
                    .ok_or("hook group hooks must be an array")?;
                if !entries.iter().all(Value::is_object) {
                    return Err("hook handlers must be objects".into());
                }
            }
        }
    }
    Ok(())
}

fn hook_specs(host: &str, handler: &Value) -> Vec<(String, Value)> {
    let events: &[&str] = if matches!(host, "claude" | "grok") {
        &["PreToolUse", "PostToolUse", "PostToolUseFailure"]
    } else {
        &["PreToolUse", "PostToolUse"]
    };
    events
        .iter()
        .map(|event| {
            (
                (*event).to_string(),
                json!({
                    "matcher": if host == "grok" { "run_terminal_command" } else { "Bash" },
                    "hooks":[handler]
                }),
            )
        })
        .collect()
}

fn hook_registrations(config: &Value, selected_handler: &Value) -> Vec<Value> {
    let mut registrations = Vec::new();
    let Some(events) = config.get("hooks").and_then(Value::as_object) else {
        return registrations;
    };
    for (event, groups) in events {
        for (group_index, group) in groups
            .as_array()
            .expect("validated groups")
            .iter()
            .enumerate()
        {
            for (hook_index, handler) in group["hooks"]
                .as_array()
                .expect("validated handlers")
                .iter()
                .enumerate()
            {
                if handler["type"] != "command" {
                    continue;
                }
                let Some(command) = handler["command"].as_str() else {
                    continue;
                };
                registrations.push(json!({
                    "event": event, "group_index": group_index, "hook_index": hook_index,
                    "matcher": group.get("matcher"), "command": command, "args": handler.get("args"),
                    "selected_instance": same_invocation(handler, selected_handler)
                }));
            }
        }
    }
    registrations
}

fn same_invocation(handler: &Value, selected_handler: &Value) -> bool {
    handler.get("command") == selected_handler.get("command")
        && handler.get("args") == selected_handler.get("args")
}

fn prune_hooks(config: &mut Value, selected_handler: &Value, remove_skills_loader: bool) -> usize {
    let Some(hooks) = config.get_mut("hooks") else {
        return 0;
    };
    let mut removed_skills_loader = 0;
    for groups in hooks.as_object_mut().expect("validated hooks").values_mut() {
        let groups = groups.as_array_mut().expect("validated array");
        groups.retain_mut(|group| {
            let handlers = group["hooks"]
                .as_array_mut()
                .expect("validated handler array");
            let count = handlers.len();
            handlers.retain(|h| {
                if h.get("type").and_then(Value::as_str) != Some("command") {
                    return true;
                }
                let Some(handler_command) = h.get("command").and_then(Value::as_str) else {
                    return true;
                };
                if remove_skills_loader && legacy::is_retired_skills_loader(handler_command) {
                    removed_skills_loader += 1;
                    return false;
                }
                !same_invocation(h, selected_handler)
            });
            handlers.len() == count || !handlers.is_empty()
        });
    }
    removed_skills_loader
}

fn prune_v1_claude_hooks(config: &mut Value) -> usize {
    let Some(events) = config.get_mut("hooks").and_then(Value::as_object_mut) else {
        return 0;
    };
    let mut removed = 0;
    for groups in events.values_mut() {
        groups
            .as_array_mut()
            .expect("validated events")
            .retain_mut(|group| {
                let handlers = group["hooks"].as_array_mut().expect("validated handlers");
                let before = handlers.len();
                handlers.retain(|handler| {
                    let owned = handler["type"] == "command"
                        && handler.get("args").is_none()
                        && handler["command"]
                            .as_str()
                            .is_some_and(legacy::is_v1_claude_hook);
                    removed += usize::from(owned);
                    !owned
                });
                handlers.len() == before || !handlers.is_empty()
            });
    }
    removed
}

fn install_binary(options: &Options) -> Result<()> {
    let current = fs::read(std::env::current_exe()?)?;
    if read_optional(&options.binary())?.as_deref() != Some(current.as_slice()) {
        write_atomic(&options.binary(), &current, 0o755)?;
    }
    make_executable(&options.binary())?;
    Ok(())
}

fn binary_changes(options: &Options) -> Result<Vec<Value>> {
    let current = fs::read(std::env::current_exe()?)?;
    let existing = read_optional(&options.binary())?;
    let mut changes = Vec::new();
    if existing.as_deref() != Some(current.as_slice()) {
        changes.push(json!({"path":options.binary(),"operation":"copy_executable"}));
    } else if !executable(&options.binary())? {
        changes.push(json!({"path":options.binary(),"operation":"restore_execute_bits"}));
    }
    Ok(changes)
}

fn preview(
    options: &Options,
    changes: Vec<Value>,
    resource_dir: &Path,
    details: Value,
) -> Result<u8> {
    eprintln!(
        "VibeGuard {} installation preview; no files were changed.",
        options.host
    );
    for change in &changes {
        eprintln!(
            "  {}: {}",
            change["operation"].as_str().unwrap_or_default(),
            change["path"].as_str().unwrap_or_default()
        );
    }
    eprintln!(
        "Installation also acquires persistent setup lock files. Unrelated handlers and user guidance are preserved."
    );
    if details["host_hook_disable_flag"] == true {
        eprintln!(
            "Host hooks are disabled; install preserves disableAllHooks. Review that setting before exercising a hook."
        );
    }
    eprintln!(
        "Next: rerun install without --dry-run, then exercise the selected integration and inspect status. Preview does not prove write access, host trust or active protection."
    );
    publish(
        json!({"action":"install","dry_run":true,"host":options.host,
        "changes":changes,"setup_locks":[options.home.join(".vibeguard/setup.lock"),resource_dir.join(".vibeguard-setup.lock")],
        "details":details,"host_trust":"not_observed",
        "note":"Read-only preview of current inputs; concurrent edits and write/metadata errors can still make installation fail."}),
        options,
        None,
    )?;
    Ok(0)
}

fn git_hook_path(options: &Options) -> Result<PathBuf> {
    let result = Command::new("git")
        .arg("-C")
        .arg(&options.repo)
        .args([
            "rev-parse",
            "--path-format=absolute",
            "--git-path",
            "hooks/pre-push",
        ])
        .output()?;
    if !result.status.success() {
        return Err("cannot resolve pre-push hook in the requested Git repository".into());
    }
    Ok(PathBuf::from(String::from_utf8(result.stdout)?.trim()))
}

fn git_integration(action: &str, options: &Options) -> Result<u8> {
    if matches!(action, "install" | "status")
        && !crate::hook_checks::inspect_git(&["--version"])?
            .status
            .success()
    {
        return Err("cannot verify Git object inspection support".into());
    }
    let path = git_hook_path(options)?;
    let expected = format!(
        "#!/bin/sh\n# VibeGuard native pre-push hook\nexec {} pre-push\n",
        quote_path(&options.binary())?
    );
    let existing = read_text(&path)?;
    let owned = existing.as_deref() == Some(expected.as_str());
    if action == "status" {
        let binary_present = read_optional(&options.binary())?.is_some();
        let binary_executable = executable(&options.binary())?;
        let hook_executable = executable(&path)?;
        publish(
            json!({"host":"git","hook":path,"configured":owned,"binary_present":binary_present,
                "binary_executable":binary_executable,"hook_executable":hook_executable,
                "user_managed_hook":existing.is_some() && !owned}),
            options,
            Some(owned && binary_executable && hook_executable),
        )?;
        return Ok(u8::from(!owned || !binary_executable || !hook_executable));
    }
    if existing.is_some() && !owned {
        return Err("existing pre-push hook is user-managed; no files were changed".into());
    }
    if options.dry_run {
        let mut changes = binary_changes(options)?;
        if !owned {
            changes.push(json!({"path":path,"operation":"register_pre_push"}));
        } else if !executable(&path)? {
            changes.push(json!({"path":path,"operation":"restore_execute_bits"}));
        }
        return preview(
            options,
            changes,
            path.parent()
                .ok_or("pre-push hook has no parent directory")?,
            json!({"hook":path,"hook_command":format!("{} pre-push",quote_path(&options.binary())?)}),
        );
    }
    let locks = if action == "install" || owned {
        let locks = lock_setup(
            &options.home,
            path.parent()
                .ok_or("pre-push hook has no parent directory")?,
        )?;
        check_unchanged(&path, existing.as_deref().map(str::as_bytes))?;
        Some(locks)
    } else {
        None
    };
    if action == "install" {
        install_binary(options)?;
        if !owned {
            write_atomic_if_unchanged(
                &path,
                expected.as_bytes(),
                0o755,
                existing.as_deref().map(str::as_bytes),
            )?;
        }
        check_unchanged(&path, Some(expected.as_bytes()))?;
        make_executable(&path)?;
    } else if owned {
        check_unchanged(&path, existing.as_deref().map(str::as_bytes))?;
        fs::remove_file(&path)?;
    }
    drop(locks);
    publish(
        json!({"action":action,"host":"git","hook":path}),
        options,
        None,
    )?;
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exec_handler_ownership_includes_arguments() {
        let ours = json!({"type":"command","command":"C:/runtime.exe","args":["hook","claude"],"timeout":10});
        let user = json!({"type":"command","command":"C:/runtime.exe","args":["rules"]});
        let mut config = json!({"hooks":{"PreToolUse":[{"hooks":[ours.clone(),user.clone()]}]}});
        assert!(hook_registrations(&config, &ours)[0]["selected_instance"] == true);
        assert!(hook_registrations(&config, &ours)[1]["selected_instance"] == false);
        prune_hooks(&mut config, &ours, false);
        assert_eq!(config["hooks"]["PreToolUse"][0]["hooks"], json!([user]));
    }
    #[test]
    fn removal_preserves_unrelated_handlers_even_in_the_same_group() {
        let ours = "/path/to/runtime hook codex";
        let user =
            json!({"type":"command","command":"echo '/path/to/runtime hook codex'","custom":true});
        let mut config = json!({"unrelated":7,"hooks":{"PreToolUse":[{"matcher":"Bash","custom":"keep","hooks":[
            {"type":"command","command":ours},user.clone()
        ]}]}});
        validate_config(&config).unwrap();
        prune_hooks(&mut config, &json!({"command":ours}), false);
        assert_eq!(config["unrelated"], 7);
        assert_eq!(config["hooks"]["PreToolUse"][0]["custom"], "keep");
        assert_eq!(config["hooks"]["PreToolUse"][0]["hooks"], json!([user]));
    }
    #[test]
    fn malformed_user_configuration_is_not_normalized_away() {
        for config in [
            json!([]),
            json!({"hooks":[]}),
            json!({"hooks":{"PreToolUse":{}}}),
            json!({"hooks":{"PreToolUse":[{"hooks":false}]}}),
        ] {
            assert!(validate_config(&config).is_err());
        }
    }
}
