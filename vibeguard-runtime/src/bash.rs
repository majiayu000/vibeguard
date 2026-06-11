#[cfg(test)]
use serde_json::json;
use std::io::{self, Read, Write};

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

pub fn run_preprocess(args: &[String]) -> Result {
    if !args.is_empty() {
        return Err("Usage: vibeguard-runtime bash-preprocess".into());
    }

    let mut command = String::new();
    io::stdin().read_to_string(&mut command)?;
    let no_heredoc = strip_heredoc_bodies(&command);
    let stripped = strip_quoted_content(&no_heredoc, false);
    let path_scan = no_heredoc.replace(['"', '\''], "");
    let stripped_with_dot = strip_quoted_content(&no_heredoc, true);

    let mut stdout = io::stdout().lock();
    for field in [&no_heredoc, &stripped, &path_scan, &stripped_with_dot] {
        stdout.write_all(field.as_bytes())?;
        stdout.write_all(&[0])?;
    }
    Ok(())
}

pub fn run_allow_command_json(args: &[String]) -> Result {
    if !args.is_empty() {
        return Err("Usage: vibeguard-runtime allow-command-json".into());
    }

    let mut command = String::new();
    io::stdin().read_to_string(&mut command)?;
    let command_json = serde_json::to_string(&command)?;
    println!("{{\"decision\": \"allow\", \"updatedInput\": {{\"command\": {command_json}}}}}");
    Ok(())
}

fn strip_heredoc_bodies(command: &str) -> String {
    let mut terminator: Option<String> = None;
    let mut strip_tabs = false;
    let mut out = String::new();

    for line in split_lines_keep_ending(command) {
        if let Some(term) = terminator.as_deref() {
            let mut candidate = line.trim_end_matches(['\r', '\n']);
            if strip_tabs {
                candidate = candidate.trim_start_matches('\t');
            }
            if candidate == term {
                terminator = None;
                strip_tabs = false;
            }
            continue;
        }

        out.push_str(line);
        if let Some((tag, tabs)) = heredoc_start(line) {
            terminator = Some(tag);
            strip_tabs = tabs;
        }
    }

    out
}

fn split_lines_keep_ending(input: &str) -> Vec<&str> {
    if input.is_empty() {
        return Vec::new();
    }

    let mut lines = Vec::new();
    let mut start = 0;
    for (idx, ch) in input.char_indices() {
        if ch == '\n' {
            lines.push(&input[start..idx + 1]);
            start = idx + 1;
        }
    }
    if start < input.len() {
        lines.push(&input[start..]);
    }
    lines
}

fn heredoc_start(line: &str) -> Option<(String, bool)> {
    let idx = line.find("<<")?;
    let mut rest = &line[idx + 2..];
    let strip_tabs = rest.strip_prefix('-').is_some();
    if strip_tabs {
        rest = &rest[1..];
    }
    rest = rest.trim_start_matches(|ch: char| ch.is_ascii_whitespace());

    let mut chars = rest.chars();
    let quote = match chars.next()? {
        '"' => Some('"'),
        '\'' => Some('\''),
        _ => None,
    };
    if quote.is_some() {
        rest = chars.as_str();
    }

    let mut tag_end = 0;
    for (idx, ch) in rest.char_indices() {
        if ch.is_ascii_alphanumeric() || ch == '_' {
            tag_end = idx + ch.len_utf8();
        } else {
            break;
        }
    }
    if tag_end == 0 {
        return None;
    }

    let tag = &rest[..tag_end];
    if let Some(q) = quote {
        if !rest[tag_end..].starts_with(q) {
            return None;
        }
    }
    Some((tag.to_string(), strip_tabs))
}

fn strip_quoted_content(command: &str, preserve_standalone_dot: bool) -> String {
    let mut out = String::with_capacity(command.len());
    let chars: Vec<(usize, char)> = command.char_indices().collect();
    let mut cursor = 0;
    let mut i = 0;

    while i < chars.len() {
        let (start, ch) = chars[i];
        if ch != '"' && ch != '\'' {
            i += 1;
            continue;
        }

        out.push_str(&command[cursor..start]);
        let mut closing = None;
        let mut j = i + 1;
        while j < chars.len() {
            if chars[j].1 == ch {
                closing = Some(chars[j].0);
                break;
            }
            j += 1;
        }

        let Some(end) = closing else {
            out.push_str(&command[start..]);
            cursor = command.len();
            break;
        };

        let content_start = start + ch.len_utf8();
        let content = &command[content_start..end];
        if preserve_standalone_dot && content == "." {
            out.push('.');
        } else {
            out.push(ch);
            out.push(ch);
        }
        cursor = end + ch.len_utf8();
        i = j + 1;
    }

    if cursor < command.len() {
        out.push_str(&command[cursor..]);
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_heredoc_bodies_but_keeps_opener() {
        let command = "cat <<'EOF'\ngit checkout .\nrm -rf /\nEOF\n";

        assert_eq!(strip_heredoc_bodies(command), "cat <<'EOF'\n");
    }

    #[test]
    fn strips_tab_heredoc_bodies() {
        let command = "cat <<-EOF\n\tgit checkout .\n\tEOF\n";

        assert_eq!(strip_heredoc_bodies(command), "cat <<-EOF\n");
    }

    #[test]
    fn quoted_content_is_replaced_without_exposing_separators() {
        let command = "git commit -m \"docs; git checkout .\" && echo 'rm -rf /'";

        assert_eq!(
            strip_quoted_content(command, false),
            "git commit -m \"\" && echo ''"
        );
    }

    #[test]
    fn standalone_quoted_dot_is_preserved_for_checkout_detection() {
        assert_eq!(
            strip_quoted_content("git checkout \".\"", true),
            "git checkout ."
        );
        assert_eq!(
            strip_quoted_content("git restore '.'", true),
            "git restore ."
        );
    }

    #[test]
    fn non_dot_quoted_content_stays_hidden_for_dot_variant() {
        let command = "echo \"note && git restore .\"";

        assert_eq!(strip_quoted_content(command, true), "echo \"\"");
    }

    #[test]
    fn allow_command_json_escapes_command_as_nested_json() {
        let value = json!({
            "decision": "allow",
            "updatedInput": {
                "command": "pnpm add \"a b\"",
            },
        });

        assert_eq!(
            value.to_string(),
            "{\"decision\":\"allow\",\"updatedInput\":{\"command\":\"pnpm add \\\"a b\\\"\"}}"
        );
    }
}
