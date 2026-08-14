use crate::setup::install_state::{read_state, state_generation, validate_state_for_preflight};
use std::fs;
use std::path::{Path, PathBuf};

const PROFILE_VALUES: &[&str] = &["minimal", "core", "full", "strict"];

pub(crate) fn installed_profile(home: &Path) -> Result<Option<String>, String> {
    let state_dir = home.join(".vibeguard");
    let current = state_dir.join("install-state.json");
    let previous = state_dir.join("install-state.previous.json");

    reject_publish_artifacts(&state_dir)?;
    let current_exists = ensure_optional_regular_file(&current)?;
    let previous_exists = ensure_optional_regular_file(&previous)?;
    if !current_exists {
        if previous_exists {
            return Err(format!(
                "VibeGuard policy error: current install-state is missing while previous snapshot exists: {}",
                previous.display()
            ));
        }
        return Ok(None);
    }

    let current_state = read_validated_state(&current)?;
    let (current_complete, current_generation) =
        state_generation(&current_state).map_err(|error| state_error(&current, error))?;
    if !current_complete {
        return Err(format!(
            "VibeGuard policy error: install-state is incomplete: {}",
            current.display()
        ));
    }

    if previous_exists {
        let previous_state = read_validated_state(&previous)?;
        let (previous_complete, previous_generation) =
            state_generation(&previous_state).map_err(|error| state_error(&previous, error))?;
        if !previous_complete {
            return Err(format!(
                "VibeGuard policy error: previous install-state is incomplete: {}",
                previous.display()
            ));
        }
        if current_generation < previous_generation {
            return Err(
                "VibeGuard policy error: current install-state generation is older than previous snapshot"
                    .to_string(),
            );
        }
    }

    let profile = current_state
        .get("profile")
        .and_then(|value| value.as_str())
        .ok_or_else(|| {
            format!(
                "VibeGuard policy error: install-state profile must be a string: {}",
                current.display()
            )
        })?;
    if !PROFILE_VALUES.contains(&profile) {
        return Err(format!(
            "VibeGuard policy error: unsupported install-state profile={profile} (expected minimal|core|full|strict)"
        ));
    }
    Ok(Some(profile.to_string()))
}

fn ensure_optional_regular_file(path: &Path) -> Result<bool, String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => Err(format!(
            "VibeGuard policy error: install-state path must be a regular file: {}",
            path.display()
        )),
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!(
            "VibeGuard policy error: cannot inspect install-state path {}: {error}",
            path.display()
        )),
    }
}

fn read_validated_state(path: &Path) -> Result<serde_json::Value, String> {
    let state = read_state(path).map_err(|error| state_error(path, error))?;
    validate_state_for_preflight(&state).map_err(|error| state_error(path, error))?;
    Ok(state)
}

fn state_error(path: &Path, error: impl std::fmt::Display) -> String {
    format!(
        "VibeGuard policy error: invalid install-state {}: {error}",
        path.display()
    )
}

fn reject_publish_artifacts(state_dir: &Path) -> Result<(), String> {
    let entries = match fs::read_dir(state_dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(format!(
                "VibeGuard policy error: cannot inspect install-state directory {}: {error}",
                state_dir.display()
            ));
        }
    };
    let mut artifacts = Vec::<PathBuf>::new();
    for entry in entries {
        let path = entry
            .map_err(|error| {
                format!(
                    "VibeGuard policy error: cannot inspect install-state directory {}: {error}",
                    state_dir.display()
                )
            })?
            .path();
        let name = path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("");
        if name.starts_with("install-state.json.next.")
            || name.starts_with("install-state.previous.json.backup.")
        {
            artifacts.push(path);
        }
    }
    if let Some(path) = artifacts.into_iter().min() {
        return Err(format!(
            "VibeGuard policy error: unfinished install-state publish artifact requires recovery: {}",
            path.display()
        ));
    }
    Ok(())
}

#[cfg(test)]
#[path = "installed_profile_tests.rs"]
mod tests;
