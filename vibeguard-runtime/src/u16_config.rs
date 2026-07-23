use crate::hook_checks_common::{absolute_parent, glob_match};
use std::fs;
use std::path::Path;

pub(crate) fn project_u16_limit(file_path: &str, base_limit: usize) -> usize {
    let mut dir = absolute_parent(file_path);
    while let Some(current) = dir {
        if current.join(".git").exists() {
            return claude_u16_limit(&current.join("CLAUDE.md"), file_path, &current, base_limit);
        }
        dir = current.parent().map(Path::to_path_buf);
    }
    base_limit
}

fn claude_u16_limit(path: &Path, file_path: &str, project_root: &Path, base_limit: usize) -> usize {
    let Ok(text) = fs::read_to_string(path) else {
        return base_limit;
    };
    u16_limit_from_claude_text(&text, file_path, project_root, base_limit)
}

pub(crate) fn u16_limit_from_claude_text(
    text: &str,
    file_path: &str,
    project_root: &Path,
    base_limit: usize,
) -> usize {
    let mut limit = base_limit;
    for line in text.lines().filter(|line| line.contains("U-16 exempt")) {
        for (pattern, value) in backtick_limit_pairs(line) {
            if u16_pattern_matches(&pattern, file_path, project_root) {
                limit = limit.max(value);
            }
        }
    }
    limit
}

fn u16_pattern_matches(pattern: &str, file_path: &str, project_root: &Path) -> bool {
    if glob_match(pattern, file_path) {
        return true;
    }
    let path = Path::new(file_path);
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        project_root.join(path)
    };
    if let Ok(relative) = absolute.strip_prefix(project_root) {
        let relative = relative.to_string_lossy().replace('\\', "/");
        return glob_match(pattern, &relative);
    }
    false
}

fn backtick_limit_pairs(line: &str) -> Vec<(String, usize)> {
    let mut pairs = Vec::new();
    let mut rest = line;
    while let Some(start) = rest.find('`') {
        rest = &rest[start + 1..];
        let Some(end) = rest.find('`') else {
            break;
        };
        let pattern = rest[..end].to_string();
        rest = &rest[end + 1..];
        let digits = rest
            .chars()
            .skip_while(|c| !c.is_ascii_digit())
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>();
        if let Ok(limit) = digits.parse::<usize>() {
            pairs.push((pattern, limit));
        }
    }
    pairs
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_project(name: &str) -> std::path::PathBuf {
        static NEXT_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        std::env::temp_dir().join(format!(
            "vibeguard-u16-config-{name}-{}-{}",
            std::process::id(),
            NEXT_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ))
    }

    #[test]
    fn project_limit_reads_exemption_from_git_root() -> Result<(), Box<dyn std::error::Error>> {
        let project_root = temp_project("configured");
        fs::create_dir_all(project_root.join(".git"))?;
        fs::create_dir_all(project_root.join("src"))?;
        fs::write(
            project_root.join("CLAUDE.md"),
            "U-16 exempt `src/generated.rs` 1500\n",
        )?;
        let file_path = project_root.join("src/generated.rs");

        assert_eq!(project_u16_limit(&file_path.to_string_lossy(), 800), 1500);

        fs::remove_dir_all(project_root)?;
        Ok(())
    }

    #[test]
    fn project_limit_falls_back_when_git_root_has_no_config()
    -> Result<(), Box<dyn std::error::Error>> {
        let project_root = temp_project("missing-config");
        fs::create_dir_all(project_root.join(".git"))?;
        fs::create_dir_all(project_root.join("src"))?;
        let file_path = project_root.join("src/main.rs");

        assert_eq!(project_u16_limit(&file_path.to_string_lossy(), 800), 800);

        fs::remove_dir_all(project_root)?;
        Ok(())
    }

    #[test]
    fn relative_u16_exemption_matches_absolute_project_path() {
        let project_root = std::env::current_dir().unwrap().join("repo-root");
        let file_path = project_root.join("src").join("large.rs");
        assert!(u16_pattern_matches(
            "src/large.rs",
            &file_path.to_string_lossy(),
            &project_root
        ));
        assert!(u16_pattern_matches(
            "src/*.rs",
            &file_path.to_string_lossy(),
            &project_root
        ));
        assert!(!u16_pattern_matches(
            "tests/*.rs",
            &file_path.to_string_lossy(),
            &project_root
        ));
    }

    #[test]
    fn limit_from_text_uses_matching_exemption_only() {
        let project_root = std::env::current_dir().unwrap().join("repo-root");
        let text = "U-16 exempt `src/generated.rs` 1500\nU-16 exempt `tests/*.rs` 2000\n";
        assert_eq!(
            u16_limit_from_claude_text(text, "src/generated.rs", &project_root, 800),
            1500
        );
        assert_eq!(
            u16_limit_from_claude_text(text, "src/main.rs", &project_root, 800),
            800
        );
    }
}
