use crate::setup::support::{basename, home_dir, shell_split};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

pub(crate) fn codex_command_is_managed(managed_scripts: &BTreeSet<String>, command: &str) -> bool {
    codex_command_is_managed_with_wrapper(managed_scripts, command, None)
}

pub(crate) fn codex_command_is_managed_with_wrapper(
    managed_scripts: &BTreeSet<String>,
    command: &str,
    wrapper: Option<&str>,
) -> bool {
    if crate::setup::hook_command_identity::command_is_managed(
        managed_scripts,
        command,
        "run-hook-codex.sh",
    ) {
        return true;
    }
    let Some(wrapper) = wrapper else {
        return false;
    };
    let wrapper_base = basename(wrapper);
    if wrapper_base == "run-hook-codex.sh" {
        return false;
    }
    crate::setup::hook_command_identity::command_is_managed(managed_scripts, command, wrapper_base)
}

pub(crate) fn codex_direct_installed_hook_target(command: &str) -> Option<PathBuf> {
    let home = home_dir()?;
    shell_split(command).into_iter().find_map(|token| {
        let path = codex_expand_path(&token, &home)?;
        path.to_string_lossy()
            .contains("/.vibeguard/installed/hooks/")
            .then_some(path)
    })
}

pub(crate) fn codex_hook_target(
    command: &str,
    script_targets: &BTreeMap<String, String>,
) -> Option<PathBuf> {
    let home = home_dir()?;
    let parts = shell_split(command);
    for (idx, token) in parts.iter().enumerate() {
        let Some(path) = codex_expand_path(token, &home) else {
            continue;
        };
        if path
            .to_string_lossy()
            .ends_with("/.vibeguard/run-hook-codex.sh")
        {
            let script = parts.get(idx + 1)?;
            if !script.contains('/') {
                let canonical_script = script_targets.get(script).unwrap_or(script);
                let installed = path
                    .parent()?
                    .join("installed/hooks")
                    .join(canonical_script);
                if installed.parent().is_some_and(Path::exists) {
                    return Some(installed);
                }
            }
        }
    }
    None
}

pub(crate) fn codex_expand_path(token: &str, home: &Path) -> Option<PathBuf> {
    token
        .strip_prefix("~/")
        .map(|tail| home.join(tail))
        .or_else(|| token.strip_prefix("$HOME/").map(|tail| home.join(tail)))
        .or_else(|| token.strip_prefix("${HOME}/").map(|tail| home.join(tail)))
        .or_else(|| token.starts_with('/').then(|| PathBuf::from(token)))
}
