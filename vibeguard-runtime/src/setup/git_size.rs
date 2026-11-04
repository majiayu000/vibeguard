//! `git-size`: the commit-time line limit for every repository on the machine. Git has
//! one place for that, the global `core.hooksPath`. If another tool already owns it, a
//! marked block goes into that tool's pre-commit hook, because a second directory can't
//! be added. If nothing does, Git is pointed at our own directory, whose hooks run each
//! repository's own hook so that setting `core.hooksPath` doesn't switch those off.

use super::*;

const BEGIN: &str = "# >>> VibeGuard line limit >>>";
const END: &str = "# <<< VibeGuard line limit <<<";
const EMPTY_HOOK: &str = "#!/bin/sh\nexit 0\n";
/// Every hook Git can run for a client or a pushed-to repository.
const HOOKS: &[&str] = &[
    "applypatch-msg",
    "commit-msg",
    "post-applypatch",
    "post-checkout",
    "post-commit",
    "post-index-change",
    "post-merge",
    "post-receive",
    "post-rewrite",
    "post-update",
    "pre-applypatch",
    "pre-auto-gc",
    "pre-commit",
    "pre-merge-commit",
    "pre-push",
    "pre-rebase",
    "pre-receive",
    "prepare-commit-msg",
    "proc-receive",
    "push-to-checkout",
    "reference-transaction",
    "sendemail-validate",
    "update",
];
const CHAIN_HOOK: &str = "#!/bin/sh\n# Runs the repository's own hook, which core.hooksPath would otherwise switch off.\nown=\"$(git rev-parse --git-common-dir 2>/dev/null)/hooks/$(basename \"$0\")\"\nif [ -x \"$own\" ]; then exec \"$own\" \"$@\"; fi\nexit 0\n";

pub(super) fn check_arguments(host: &str, repo: Option<&PathBuf>) -> Result<()> {
    if host == "git-size" && repo.is_some() {
        return Err("git-size covers every repository on this machine, so it takes no --repo. To turn it off in one repository: git -C PATH config vibeguard.sizeLimit false".into());
    }
    Ok(())
}

pub(super) fn summary(ready: bool) -> &'static str {
    if ready {
        "VibeGuard git-size setup complete for this machine; a repository's own core.hooksPath would bypass it. Next: verify during your next normal commit."
    } else {
        "VibeGuard git-size setup incomplete. Next: run install git-size, then inspect hooks_path and hook in the status JSON."
    }
}

fn global_config(options: &Options, args: &[&str]) -> Result<std::process::Output> {
    Ok(Command::new("git")
        .env("HOME", &options.home)
        .args(["config", "--global"])
        .args(args)
        .output()?)
}

/// The global `core.hooksPath`, if one is set.
fn hooks_path(options: &Options) -> Result<Option<PathBuf>> {
    let output = global_config(options, &["--type=path", "--get", "core.hooksPath"])?;
    match output.status.code() {
        Some(0) => {}
        Some(1) => return Ok(None),
        _ => return Err("cannot read the global core.hooksPath".into()),
    }
    let path = PathBuf::from(String::from_utf8(output.stdout)?.trim());
    if !path.is_absolute() {
        return Err(format!(
            "the global core.hooksPath {} is relative, so it names a different directory in each repository; no files were changed",
            path.display()
        )
        .into());
    }
    Ok(Some(path))
}

fn block(options: &Options) -> Result<String> {
    let binary = quote_path(&options.binary())?;
    // Without the binary the check is skipped: losing it must not stop every commit.
    Ok(format!(
        "{BEGIN}\nif [ \"$(basename \"$0\")\" = pre-commit ] && [ -x {binary} ]; then\n  {binary} pre-commit || exit $?\nfi\n{END}\n"
    ))
}

fn without_block(text: &str) -> Result<String> {
    let Some(start) = text.find(BEGIN) else {
        return Ok(text.to_owned());
    };
    let end = text[start..]
        .find(END)
        .ok_or("the VibeGuard block in the hook has no end marker; no files were changed")?;
    let after = text[start + end + END.len()..]
        .strip_prefix('\n')
        .unwrap_or(&text[start + end + END.len()..]);
    Ok(format!("{}{after}", &text[..start]))
}

/// `text` with the block right after its first line, replacing an older one.
fn with_block(text: &str, block: &str, file: &Path) -> Result<String> {
    let text = without_block(text)?;
    let (first, rest) = text.split_once('\n').unwrap_or((&text, ""));
    if !(first.starts_with("#!") && first.contains("sh")) {
        return Err(format!(
            "{} is not a shell script, so VibeGuard can't add to it; no files were changed. Call `vibeguard-runtime pre-commit` from it yourself",
            file.display()
        )
        .into());
    }
    Ok(format!("{first}\n{block}{rest}"))
}

pub(super) fn run(action: &str, options: &Options) -> Result<u8> {
    let own_dir = options.home.join(".vibeguard/git-hooks");
    let configured_dir = hooks_path(options)?;
    let dir = configured_dir.clone().unwrap_or_else(|| own_dir.clone());
    // The hook may be a link into a script its owner shares between hooks.
    let link = dir.join("pre-commit");
    let file = fs::canonicalize(&link).unwrap_or(link);
    let existing = read_text(&file)?;
    let wanted = block(options)?;
    let has_block = existing.as_deref().is_some_and(|t| t.contains(&wanted));
    let configured = configured_dir.is_some() && has_block;
    if action == "status" {
        let binary_present = read_optional(&options.binary())?.is_some();
        let binary_executable = executable(&options.binary())?;
        let hook_executable = executable(&file)?;
        let ready = configured && binary_executable && hook_executable;
        publish(
            json!({"host":options.host,"scope":"machine","hooks_path":dir,"hook":file,"configured":configured,
                "binary_present":binary_present,"binary_executable":binary_executable,"hook_executable":hook_executable}),
            options,
            Some(ready),
        )?;
        return Ok(u8::from(!ready));
    }
    let next = match action {
        "install" => Some(with_block(
            existing.as_deref().unwrap_or(EMPTY_HOOK),
            &wanted,
            &file,
        )?),
        _ => existing.as_deref().map(without_block).transpose()?,
    };
    if options.dry_run {
        let mut changes = binary_changes(options)?;
        if !configured {
            changes.push(json!({"path":file,"operation":"add_line_limit_to_pre_commit"}));
        }
        if configured_dir.is_none() {
            changes.push(
                json!({"path":own_dir,"operation":"create_hooks_that_run_each_repository_hook"}),
            );
            changes.push(json!({"path":"core.hooksPath","operation":"set_global_git_config"}));
        }
        return preview(
            options,
            changes,
            &dir,
            json!({"scope":"machine","hooks_path":dir,"hook":file}),
        );
    }
    let locks = lock_setup(&options.home, &dir)?;
    check_unchanged(&file, existing.as_deref().map(str::as_bytes))?;
    let ours = dir == own_dir;
    if action == "install" {
        install_binary(options)?;
        let next = next.ok_or("no hook content to install")?;
        if configured_dir.is_none() {
            for name in HOOKS.iter().filter(|name| **name != "pre-commit") {
                let path = dir.join(name);
                write_atomic(&path, CHAIN_HOOK.as_bytes(), 0o755)?;
                make_executable(&path)?;
            }
        }
        // Our own pre-commit also chains; another tool's keeps its own behavior.
        let content = if ours {
            with_block(CHAIN_HOOK, &wanted, &file)?
        } else {
            next
        };
        if existing.as_deref() != Some(content.as_str()) {
            write_atomic_if_unchanged(
                &file,
                content.as_bytes(),
                0o755,
                existing.as_deref().map(str::as_bytes),
            )?;
        }
        make_executable(&file)?;
        if configured_dir.is_none() {
            let value = own_dir.to_str().ok_or("hook paths must be valid UTF-8")?;
            if !global_config(options, &["core.hooksPath", value])?
                .status
                .success()
            {
                return Err("could not set the global core.hooksPath".into());
            }
        }
    } else if ours && configured_dir.is_some() {
        if !global_config(options, &["--unset", "core.hooksPath"])?
            .status
            .success()
        {
            return Err("could not unset the global core.hooksPath".into());
        }
    } else if let Some(next) = next
        && existing.as_deref() != Some(next.as_str())
    {
        // A hook we created for another tool's directory goes away again with us.
        if next == EMPTY_HOOK {
            fs::remove_file(&file)?;
        } else {
            write_atomic_if_unchanged(
                &file,
                next.as_bytes(),
                0o755,
                existing.as_deref().map(str::as_bytes),
            )?;
        }
    }
    drop(locks);
    if action == "uninstall" && ours && own_dir.exists() {
        fs::remove_dir_all(&own_dir)?;
    }
    publish(
        json!({"action":action,"host":options.host,"scope":"machine","hooks_path":dir,"hook":file}),
        options,
        None,
    )?;
    Ok(0)
}
