use crate::setup_support::SetupResult;
use std::fs;
use std::path::{Path, PathBuf};

pub(super) fn inject_collision(candidate: &Path) -> SetupResult<()> {
    if std::env::var_os("VIBEGUARD_TEST_REMOVE_COLLIDE_ALL").is_some() {
        fs::create_dir(candidate)?;
        fs::write(candidate.join("collision-sentinel"), "collision\n")?;
    }
    Ok(())
}

pub(super) fn inject_postverify(quarantine: &Path) -> SetupResult<()> {
    if let Some(name) = std::env::var_os("VIBEGUARD_TEST_REMOVE_POSTVERIFY_INJECT") {
        let name = PathBuf::from(name);
        if name.components().count() != 1 || name.as_os_str().is_empty() {
            return Err("test injection name must be one non-empty path component".into());
        }
        fs::write(quarantine.join(name), "user-data\n")?;
    }
    Ok(())
}

pub(super) fn inject_public_replacement(dest: &Path) -> SetupResult<()> {
    if let Some(value) = std::env::var_os("VIBEGUARD_TEST_REMOVE_PUBLIC_REPLACEMENT") {
        fs::create_dir(dest)?;
        fs::write(dest.join("custom.txt"), value.to_string_lossy().as_bytes())?;
    }
    Ok(())
}

pub(super) fn inject_failure(variable: &str, message: &str) -> SetupResult<()> {
    if std::env::var_os(variable).is_some() {
        return Err(message.into());
    }
    Ok(())
}
