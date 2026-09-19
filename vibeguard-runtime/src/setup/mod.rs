mod markdown;
pub mod support;

use crate::{Result, logging, print_json};
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use support::{executable, make_executable, read_optional, read_text, shell_quote, write_atomic};

struct Options {
    host: String,
    home: PathBuf,
    host_dir: PathBuf,
    repo: PathBuf,
}

impl Options {
    fn parse(args: &[String]) -> Result<Self> {
        let host = args
            .first()
            .filter(|v| matches!(v.as_str(), "claude" | "codex" | "git"))
            .ok_or("target must be claude, codex or git")?
            .clone();
        let mut explicit_home = None;
        let mut repo = None;
        let mut rest = args[1..].iter();
        while let Some(flag) = rest.next() {
            let value = rest.next().ok_or("option requires a path")?;
            match flag.as_str() {
                "--home" if explicit_home.is_none() => explicit_home = Some(PathBuf::from(value)),
                "--repo" if host == "git" && repo.is_none() => repo = Some(PathBuf::from(value)),
                _ => return Err("unknown or repeated installation option".into()),
            }
        }
        let is_explicit = explicit_home.is_some();
        let home = explicit_home
            .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
            .filter(|p| !p.as_os_str().is_empty())
            .ok_or("HOME is unavailable; pass --home PATH")?;
        let home = absolute(home)?;
        let host_dir = if host == "codex" && !is_explicit {
            std::env::var_os("CODEX_HOME")
                .filter(|p| !p.is_empty())
                .map(PathBuf::from)
                .map(absolute)
                .transpose()?
                .unwrap_or_else(|| home.join(".codex"))
        } else {
            home.join(format!(".{host}"))
        };
        Ok(Self {
            host,
            home,
            host_dir,
            repo: absolute(repo.unwrap_or(std::env::current_dir()?))?,
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
        self.host_dir.join(if self.host == "codex" {
            "hooks.json"
        } else {
            "settings.json"
        })
    }
    fn instructions(&self) -> PathBuf {
        self.host_dir.join(if self.host == "codex" {
            "AGENTS.md"
        } else {
            "CLAUDE.md"
        })
    }
    fn command(&self) -> Result<String> {
        Ok(format!(
            "{} hook {} --state-dir {}",
            quote_path(&self.binary())?,
            self.host,
            quote_path(&self.state())?
        ))
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
    if action != "status" && !cfg!(unix) {
        return Err("native installation currently supports macOS, Linux and WSL; no configuration was changed".into());
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
    let instructions_path = options.instructions();
    let old_instructions = read_text(&instructions_path)?;
    let old_text = old_instructions.as_deref().unwrap_or("");
    let core_present = markdown::contains(old_text)?;
    let command = options.command()?;
    let specs = hook_specs(&options.host, &command);
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
        print_json(&json!({
            "host": options.host, "config": config_path, "configured": configured,
            "core_present": core_present, "binary_present": binary_present,
            "binary_executable": binary_executable,
            "host_hooks_feature_enabled": feature_enabled,
            "host_hook_disable_flag": disabled, "host_trust": "not_observed",
            "last_observation": logging::latest(&options.state(), &options.host)?,
            "coverage": "registered Bash events only; not a sandbox or task-verification certificate"
        }))?;
        return Ok(u8::from(
            !configured
                || !core_present
                || !binary_executable
                || disabled == Some(true)
                || feature_enabled == Some(false),
        ));
    }
    let replacement = markdown::block(&quote_path(&options.binary())?);
    let new_instructions = markdown::update(
        old_text,
        (action == "install").then_some(replacement.as_str()),
    )?;
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
    prune_own_hooks(&mut config, &command);
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
        install_binary(&options)?;
    }
    if config != original_config {
        write_atomic(
            &config_path,
            (serde_json::to_string_pretty(&config)? + "\n").as_bytes(),
            0o600,
        )?;
    }
    if let Some(text) = new_features
        && old_features.as_deref() != Some(&text)
    {
        write_atomic(&feature_path, text.as_bytes(), 0o600)?;
    }
    if new_instructions != old_text {
        if new_instructions.is_empty() {
            fs::remove_file(&instructions_path)?;
        } else {
            write_atomic(&instructions_path, new_instructions.as_bytes(), 0o600)?;
        }
    }
    if action == "uninstall" {
        let observation = options.state().join(format!("{}.json", options.host));
        if read_optional(&observation)?.is_some() {
            fs::remove_file(observation)?;
        }
    }
    print_json(&json!({
        "action":action,"host":options.host,"config":config_path,"instructions":instructions_path,
        "binary":options.binary(),
        "note": if action == "install" {
            "Registered. Restart the host and review its hook trust settings; configuration alone does not prove execution."
        } else {
            "Integration removed. The shared binary remains for other hosts and direct CLI use."
        }
    }))?;
    Ok(0)
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

fn hook_specs(host: &str, command: &str) -> Vec<(String, Value)> {
    let events: &[&str] = if host == "claude" {
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
                    "matcher":"Bash","hooks":[{"type":"command","command":command,"timeout":10}]
                }),
            )
        })
        .collect()
}

fn prune_own_hooks(config: &mut Value, command: &str) {
    let Some(hooks) = config.get_mut("hooks") else {
        return;
    };
    for groups in hooks.as_object_mut().expect("validated hooks").values_mut() {
        let groups = groups.as_array_mut().expect("validated array");
        groups.retain_mut(|group| {
            let handlers = group["hooks"]
                .as_array_mut()
                .expect("validated handler array");
            let count = handlers.len();
            handlers.retain(|h| {
                !(h.get("type").and_then(Value::as_str) == Some("command")
                    && h.get("command").and_then(Value::as_str) == Some(command))
            });
            handlers.len() == count || !handlers.is_empty()
        });
    }
}

fn install_binary(options: &Options) -> Result<()> {
    let current = fs::read(std::env::current_exe()?)?;
    if read_optional(&options.binary())?.as_deref() != Some(current.as_slice()) {
        write_atomic(&options.binary(), &current, 0o755)?;
    }
    make_executable(&options.binary())?;
    Ok(())
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
        print_json(
            &json!({"host":"git","hook":path,"configured":owned,"binary_present":binary_present,
                "binary_executable":binary_executable,"hook_executable":hook_executable}),
        )?;
        return Ok(u8::from(!owned || !binary_executable || !hook_executable));
    }
    if existing.is_some() && !owned {
        return Err("existing pre-push hook is user-managed; no files were changed".into());
    }
    if action == "install" {
        install_binary(options)?;
        if !owned {
            write_atomic(&path, expected.as_bytes(), 0o755)?;
        }
        make_executable(&path)?;
    } else if owned {
        fs::remove_file(&path)?;
    }
    print_json(&json!({"action":action,"host":"git","hook":path}))?;
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn removal_preserves_unrelated_handlers_even_in_the_same_group() {
        let ours = "/path/to/runtime hook codex";
        let user =
            json!({"type":"command","command":"echo '/path/to/runtime hook codex'","custom":true});
        let mut config = json!({"unrelated":7,"hooks":{"PreToolUse":[{"matcher":"Bash","custom":"keep","hooks":[
            {"type":"command","command":ours},user.clone()
        ]}]}});
        validate_config(&config).unwrap();
        prune_own_hooks(&mut config, ours);
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
