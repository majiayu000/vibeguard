//! Installing, checking and removing the pre-push hook for one repository.

use super::*;

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

pub(super) fn git_integration(action: &str, options: &Options) -> Result<u8> {
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
            path.parent().ok_or("Git hook has no parent directory")?,
            json!({"hook":path,"hook_command":format!("{} pre-push",quote_path(&options.binary())?)}),
        );
    }
    let locks = if action == "install" || owned {
        let locks = lock_setup(
            &options.home,
            path.parent().ok_or("Git hook has no parent directory")?,
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
