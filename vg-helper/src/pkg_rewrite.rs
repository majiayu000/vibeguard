//! Package manager transparent correction: npm/yarn→pnpm, pip→uv.
//! Canonical implementation. hooks/_lib/pkg_rewrite.py is a deprecated fallback.

use regex::Regex;
use std::io::{self, Read};

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

/// Reads a shell command from stdin, prints corrected command or empty string.
pub fn run(_args: &[String]) -> Result {
    let mut cmd = String::new();
    io::stdin().read_to_string(&mut cmd)?;
    let cmd = cmd.trim();

    println!("{}", rewrite_command(cmd).unwrap_or_default());
    Ok(())
}

fn rewrite_command(cmd: &str) -> Option<String> {
    // Skip complex commands (&&, ||, ;, pipe, redirection, $(), backtick)
    let complex = Regex::new(r"&&|&|\|\||;|[|<>\n\r]|\$\(|`").ok()?;
    if complex.is_match(cmd) {
        return None;
    }

    try_npm(cmd)
        .or_else(|| try_yarn(cmd))
        .or_else(|| try_pip(cmd))
        .or_else(|| try_python_pip(cmd))
}

fn try_npm(cmd: &str) -> Option<String> {
    let bare_install = Regex::new(r"^npm\s+(?:install|i)\s*$").ok()?;
    if bare_install.is_match(cmd) {
        return Some("pnpm install".into());
    }

    let pkg_install = Regex::new(r"^npm\s+(?:install|i|add)\s+").ok()?;
    if !pkg_install.is_match(cmd) {
        return None;
    }
    let rest = pkg_install.replace(cmd, "").trim().to_string();
    let tokens: Vec<&str> = rest.split_whitespace().collect();

    const KNOWN: &[&str] = &[
        "--save-dev",
        "-D",
        "--save",
        "-S",
        "--save-optional",
        "-O",
        "--save-exact",
        "-E",
    ];
    if tokens
        .iter()
        .any(|t| *t == "-g" || *t == "--global" || t.starts_with("--location=global"))
    {
        return None;
    }
    if tokens
        .iter()
        .any(|t| t.starts_with('-') && !KNOWN.contains(t))
    {
        return None;
    }
    let packages: Vec<&str> = tokens
        .iter()
        .filter(|t| !t.starts_with('-'))
        .copied()
        .collect();
    if packages.is_empty() {
        return None;
    }

    let mut flags = Vec::new();
    for t in &tokens {
        match *t {
            "--save-dev" | "-D" => flags.push("-D"),
            "--save-optional" | "-O" => flags.push("-O"),
            "--save-exact" | "-E" => flags.push("--save-exact"),
            _ => {}
        }
    }
    flags.extend(packages);
    Some(format!("pnpm add {}", flags.join(" ")))
}

fn try_yarn(cmd: &str) -> Option<String> {
    let bare = Regex::new(r"^yarn\s+install\s*$").ok()?;
    if bare.is_match(cmd) {
        return Some("pnpm install".into());
    }

    let add = Regex::new(r"^yarn\s+add\s+").ok()?;
    if !add.is_match(cmd) {
        return None;
    }
    let rest = add.replace(cmd, "").to_string();
    let tokens: Vec<&str> = rest.split_whitespace().collect();

    const KNOWN: &[&str] = &[
        "-D",
        "--dev",
        "--save-dev",
        "-O",
        "--optional",
        "-E",
        "--exact",
        "-P",
        "--save-peer",
        "-W",
        "--ignore-workspace-root-check",
    ];
    if tokens
        .iter()
        .any(|t| t.starts_with('-') && !KNOWN.contains(t))
    {
        return None;
    }
    let packages: Vec<&str> = tokens
        .iter()
        .filter(|t| !t.starts_with('-'))
        .copied()
        .collect();
    if packages.is_empty() {
        return None;
    }

    let mut flags = Vec::new();
    for t in &tokens {
        match *t {
            "-D" | "--dev" | "--save-dev" => flags.push("-D"),
            "-O" | "--optional" => flags.push("-O"),
            "-E" | "--exact" => flags.push("--save-exact"),
            "-P" | "--save-peer" => flags.push("--save-peer"),
            "-W" | "--ignore-workspace-root-check" => flags.push("-w"),
            _ => {}
        }
    }
    flags.extend(packages);
    Some(format!("pnpm add {}", flags.join(" ")))
}

fn try_pip(cmd: &str) -> Option<String> {
    let re = Regex::new(r"^pip3?\s+install\s+").ok()?;
    if !re.is_match(cmd) {
        return None;
    }
    let rest = re.replace(cmd, "").to_string();
    check_pip_flags(&rest).map(|_| format!("uv pip install {rest}"))
}

fn try_python_pip(cmd: &str) -> Option<String> {
    let re = Regex::new(r"^python3?\s+-m\s+pip\s+install\s+").ok()?;
    if !re.is_match(cmd) {
        return None;
    }
    let rest = re.replace(cmd, "").to_string();
    check_pip_flags(&rest).map(|_| format!("uv pip install {rest}"))
}

fn check_pip_flags(rest: &str) -> Option<()> {
    const KNOWN: &[&str] = &[
        "-r",
        "--requirement",
        "-e",
        "--editable",
        "-U",
        "--upgrade",
        "--pre",
        "--no-deps",
        "-i",
        "--index-url",
        "--extra-index-url",
        "--no-index",
        "-f",
        "--find-links",
        "-c",
        "--constraint",
        "-v",
        "--verbose",
        "-q",
        "--quiet",
        "-t",
        "--target",
    ];
    let tokens: Vec<&str> = rest.split_whitespace().collect();
    if tokens
        .iter()
        .any(|t| t.starts_with('-') && !KNOWN.contains(t))
    {
        return None;
    }
    Some(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn npm_bare_install_rewrites_to_pnpm_install() {
        assert_eq!(rewrite_command("npm install"), Some("pnpm install".into()));
        assert_eq!(rewrite_command("npm i"), Some("pnpm install".into()));
    }

    #[test]
    fn npm_package_install_rewrites_supported_flags() {
        assert_eq!(
            rewrite_command("npm install --save-dev --save-exact vitest @types/node"),
            Some("pnpm add -D --save-exact vitest @types/node".into())
        );
        assert_eq!(
            rewrite_command("npm add -O sharp"),
            Some("pnpm add -O sharp".into())
        );
    }

    #[test]
    fn npm_global_or_unknown_flags_do_not_rewrite() {
        assert_eq!(rewrite_command("npm install -g typescript"), None);
        assert_eq!(
            rewrite_command("npm install --legacy-peer-deps react"),
            None
        );
    }

    #[test]
    fn yarn_install_and_add_rewrite_to_pnpm() {
        assert_eq!(rewrite_command("yarn install"), Some("pnpm install".into()));
        assert_eq!(
            rewrite_command("yarn add --dev --exact eslint"),
            Some("pnpm add -D --save-exact eslint".into())
        );
        assert_eq!(
            rewrite_command("yarn add -P -W react"),
            Some("pnpm add --save-peer -w react".into())
        );
    }

    #[test]
    fn yarn_unknown_flags_do_not_rewrite() {
        assert_eq!(rewrite_command("yarn add --frozen-lockfile react"), None);
    }

    #[test]
    fn pip_install_rewrites_known_forms() {
        assert_eq!(
            rewrite_command("pip install requests"),
            Some("uv pip install requests".into())
        );
        assert_eq!(
            rewrite_command("pip3 install -r requirements.txt"),
            Some("uv pip install -r requirements.txt".into())
        );
    }

    #[test]
    fn python_module_pip_rewrites_known_forms() {
        assert_eq!(
            rewrite_command("python -m pip install -e ."),
            Some("uv pip install -e .".into())
        );
        assert_eq!(
            rewrite_command("python3 -m pip install --upgrade build"),
            Some("uv pip install --upgrade build".into())
        );
    }

    #[test]
    fn pip_unknown_flags_do_not_rewrite() {
        assert_eq!(rewrite_command("pip install --user requests"), None);
        assert_eq!(
            rewrite_command("python3 -m pip install --user requests"),
            None
        );
    }

    #[test]
    fn complex_commands_do_not_rewrite() {
        for cmd in [
            "npm install && npm test",
            "pip install requests | cat",
            "yarn add react > out.txt",
            "npm install $(cat package.txt)",
            "npm install `cat package.txt`",
        ] {
            assert_eq!(rewrite_command(cmd), None, "{cmd}");
        }
    }
}
