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
/// Git updates the work tree of a pushed-to branch itself, unless a push-to-checkout hook
/// exists: then that is left to the hook. So where the repository has none of its own
/// to run, ours does what Git does without one, `push_to_deploy` in its receive-pack.
const PUSH_TO_CHECKOUT_HOOK: &str = r#"#!/bin/sh
# Runs the repository's own hook, which core.hooksPath would otherwise switch off.
own="$(git rev-parse --git-common-dir 2>/dev/null)/hooks/push-to-checkout"
if [ -x "$own" ]; then exec "$own" "$@"; fi
# Git leaves the work tree to this hook because it exists. This is Git's own update.
refuse() { echo "$1" >&2; exit 1; }
git update-index -q --ignore-submodules --refresh || refuse "Up-to-date check failed"
git diff-files --quiet --ignore-submodules -- || refuse "Working directory has unstaged changes"
head=HEAD
git rev-parse -q --verify HEAD >/dev/null || head=$(git hash-object -t tree /dev/null)
git diff-index --quiet --cached --ignore-submodules "$head" -- || refuse "Working directory has staged changes"
git read-tree -u -m "$1" || refuse "Could not update working tree to new HEAD"
"#;

/// The hook our own directory holds under `name`.
fn chain_hook(name: &str) -> &'static str {
    if name == "push-to-checkout" {
        PUSH_TO_CHECKOUT_HOOK
    } else {
        CHAIN_HOOK
    }
}

/// The push-to-checkout hook 2.3.0 wrote into our directory, if it is still there. It
/// only passed the call on, so a push Git would have checked out left the work tree
/// behind. A hook another tool has put in its place is not ours to replace.
fn outdated_push_to_checkout(own_dir: &Path) -> Result<Option<PathBuf>> {
    let path = own_dir.join("push-to-checkout");
    Ok((read_text(&path)?.as_deref() == Some(CHAIN_HOOK)).then_some(path))
}

/// Whether `text` is a hook from our own directory. It only passes the call on, so the
/// hook in effect is the repository's own, under its common directory's `hooks`.
pub(super) fn runs_repository_hook(text: &str) -> bool {
    without_block(text).is_ok_and(|hook| hook == CHAIN_HOOK)
}

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

fn config(options: &Options, args: &[&str]) -> Result<std::process::Output> {
    let mut git = Command::new("git");
    git.env("HOME", &options.home);
    // An explicit --home is an isolated installation. Where the environment moves the
    // global configuration to belongs to the account, and Git would follow it past HOME.
    if options.explicit_home {
        git.env_remove("GIT_CONFIG_GLOBAL")
            .env_remove("XDG_CONFIG_HOME");
    }
    Ok(git.arg("config").args(args).output()?)
}

/// The `core.hooksPath` a repository gets when it sets none of its own, if there is
/// one: the last in the system and global configuration and the files they include.
/// `git config --global` reads the main global file only.
fn hooks_path(options: &Options) -> Result<Option<PathBuf>> {
    let output = config(
        options,
        &[
            "--show-scope",
            "--null",
            "--type=path",
            "--get-all",
            "core.hooksPath",
        ],
    )?;
    match output.status.code() {
        Some(0) => {}
        Some(1) => return Ok(None),
        _ => return Err("cannot read the global core.hooksPath".into()),
    }
    // Scope and value by turns, in the order Git applies them. The repository this
    // runs in and the command line have scopes of their own, which aren't the machine's.
    let text = String::from_utf8(output.stdout)?;
    let mut fields = text.split('\0');
    let mut last = None;
    while let (Some(scope), Some(value)) = (fields.next(), fields.next()) {
        if matches!(scope, "system" | "global") {
            last = Some(value);
        }
    }
    let Some(path) = last.map(PathBuf::from) else {
        return Ok(None);
    };
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

pub(super) fn without_block(text: &str) -> Result<String> {
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

/// Whether a script's first line names a shell that reads the block as written: POSIX
/// `if`, `[` and `$(...)`. The name is what counts, straight or after `env`, not the
/// letters "sh" somewhere in the line: `.pyenv/shims/python` has them, and so do fish
/// and tcsh, which read `if` another way.
fn posix_shell_runs(first_line: &str) -> bool {
    let name = |word: &str| word.rsplit('/').next().unwrap_or(word).to_owned();
    let mut words = first_line
        .strip_prefix("#!")
        .unwrap_or("")
        .split_whitespace();
    let mut interpreter = words.next().map(name);
    if interpreter.as_deref() == Some("env") {
        // `env -S bash -e`, `env LC_ALL=C sh`: past env's options and assignments.
        interpreter = words
            .find(|word| !word.starts_with('-') && !word.contains('='))
            .map(name);
    }
    matches!(
        interpreter.as_deref(),
        Some("sh" | "bash" | "dash" | "zsh" | "ksh" | "ash")
    )
}

/// `text` with the block right after its first line, replacing an older one.
fn with_block(text: &str, block: &str, file: &Path) -> Result<String> {
    let text = without_block(text)?;
    let (first, rest) = text.split_once('\n').unwrap_or((&text, ""));
    if !posix_shell_runs(first) {
        return Err(format!(
            "{} is not a POSIX shell script, so VibeGuard can't add to it; no files were changed. Call `vibeguard-runtime pre-commit` from it yourself",
            file.display()
        )
        .into());
    }
    Ok(format!("{first}\n{block}{rest}"))
}

pub(super) fn run(action: &str, options: &Options) -> Result<u8> {
    // The commit-time check lets commits through when Git can't run its inspections, so
    // install and status make sure it can, as `install git` does; uninstall still works.
    if matches!(action, "install" | "status")
        && !crate::hook_checks::inspect_git(&["--version"])?
            .status
            .success()
    {
        return Err("cannot verify Git object inspection support".into());
    }
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
    let ours = dir == own_dir;
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
        } else if ours && let Some(path) = outdated_push_to_checkout(&dir)? {
            changes.push(json!({"path":path,"operation":"update_push_to_checkout_hook"}));
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
    if action == "install" {
        install_binary(options)?;
        let next = next.ok_or("no hook content to install")?;
        if configured_dir.is_none() {
            for name in HOOKS.iter().filter(|name| **name != "pre-commit") {
                let path = dir.join(name);
                write_atomic(&path, chain_hook(name).as_bytes(), 0o755)?;
                make_executable(&path)?;
            }
        } else if ours && let Some(path) = outdated_push_to_checkout(&dir)? {
            write_atomic(&path, PUSH_TO_CHECKOUT_HOOK.as_bytes(), 0o755)?;
            make_executable(&path)?;
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
            if !config(options, &["--global", "core.hooksPath", value])?
                .status
                .success()
            {
                return Err("could not set the global core.hooksPath".into());
            }
        }
    } else if ours && configured_dir.is_some() {
        if !config(options, &["--global", "--unset", "core.hooksPath"])?
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
    if action == "install" && ours {
        eprintln!(
            "Third-party tools can refuse to install hooks under VibeGuard's shared Git hooks path. In a standard clone, run `git -c core.hooksPath=.git/hooks lfs install --local` before pushing Git LFS files."
        );
    }
    publish(
        json!({"action":action,"host":options.host,"scope":"machine","hooks_path":dir,"hook":file}),
        options,
        None,
    )?;
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_block_goes_only_into_a_script_a_posix_shell_runs() {
        let add = |first: &str| {
            let hook = format!("{first}\nmine\n");
            with_block(&hook, "block\n", Path::new("pre-commit"))
        };
        for first in [
            "#!/bin/sh",
            "#! /bin/bash -e",
            "#!/opt/homebrew/bin/zsh",
            "#!/usr/bin/env dash",
            "#!/usr/bin/env -S ksh -e",
        ] {
            assert_eq!(add(first).unwrap(), format!("{first}\nblock\nmine\n"));
        }
        // The letters "sh" in a path or a name, and shells that read `if` another way.
        for first in [
            "#!/home/josh/.pyenv/shims/python",
            "#!/usr/share/tool/bin/node",
            "#!/usr/bin/env python3",
            "#!/usr/bin/env fish",
            "#!/bin/tcsh -f",
            "#!/usr/bin/pwsh",
            "#!/usr/bin/tclsh",
            "echo no interpreter line",
        ] {
            assert!(add(first).is_err(), "{first}");
        }
    }
}
