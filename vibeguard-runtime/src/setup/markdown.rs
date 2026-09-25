use crate::Result;
use std::ops::Range;

const START: &str = "<!-- vibeguard-core:start -->";
const END: &str = "<!-- vibeguard-core:end -->";

pub fn block(command: &str) -> String {
    format!(
        "{START}\n{}\nRead only relevant rules with `{command} rules ID` or list categories with `{command} rules`. Rules are review guidance; use this repository's actual check commands.\n{END}\n",
        crate::rules::CORE.trim_end()
    )
}

pub fn update(original: &str, replacement: Option<&str>) -> Result<String> {
    match region(original)? {
        Some(range) => {
            let mut result = original.to_string();
            result.replace_range(range, replacement.unwrap_or(""));
            Ok(result)
        }
        None => Ok(format!("{}{original}", replacement.unwrap_or(""))),
    }
}

pub fn matches_block(original: &str, expected: &str) -> Result<bool> {
    // Line endings and a final newline do not change the instruction content.
    Ok(region(original)?.is_some_and(|range| original[range].lines().eq(expected.lines())))
}

fn region(text: &str) -> Result<Option<Range<usize>>> {
    let mut starts = Vec::new();
    let mut ends = Vec::new();
    let mut fence: Option<(u8, usize)> = None;
    let mut offset = 0;
    for segment in text.split_inclusive('\n') {
        let line = segment.trim_end_matches(['\r', '\n']);
        let trimmed = line.trim_start_matches(' ');
        let indent = line.len() - trimmed.len();
        let run = trimmed.as_bytes().first().copied().and_then(|marker| {
            let length = trimmed.bytes().take_while(|b| *b == marker).count();
            (indent <= 3 && matches!(marker, b'`' | b'~') && length >= 3)
                .then(|| (marker, length, &trimmed[length..]))
        });
        if let Some((marker, minimum)) = fence {
            if run.is_some_and(|(candidate, length, rest)| {
                candidate == marker && length >= minimum && rest.trim().is_empty()
            }) {
                fence = None;
            }
        } else if let Some((marker, length, rest)) = run {
            if marker != b'`' || !rest.contains('`') {
                fence = Some((marker, length));
            }
        } else if line == START {
            starts.push(offset);
        } else if line == END {
            ends.push(offset + segment.len());
        }
        offset += segment.len();
    }
    match (&starts[..], &ends[..]) {
        ([], []) => Ok(None),
        ([start], [end]) if start < end => Ok(Some(*start..*end)),
        _ => Err("instruction file has incomplete, reversed or duplicate VibeGuard core markers; no changes written".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn current_block_matches_content_with_equivalent_line_endings() {
        let expected = block("'/current/vibeguard-runtime'");
        for text in [
            expected.clone(),
            expected.replace('\n', "\r\n"),
            expected.trim_end_matches('\n').to_string(),
            format!("User notes\n{expected}More notes without final newline"),
        ] {
            assert!(matches_block(&text, &expected).unwrap());
        }
        for text in [
            String::new(),
            format!("{START}\n{END}\n"),
            expected.replace("/current/", "/previous/"),
            expected.replace("- U-29: Preserve the operation's error contract.\n", ""),
        ] {
            assert!(!matches_block(&text, &expected).unwrap());
        }
        assert!(matches_block(START, &expected).is_err());
    }
    #[test]
    fn preserves_exact_unmanaged_bytes() {
        let original = "# User notes\r\nCustom instruction without final newline";
        let managed = block("vibeguard-runtime");
        let installed = update(original, Some(&managed)).unwrap();
        assert_eq!(update(&installed, Some(&managed)).unwrap(), installed);
        assert_eq!(update(&installed, None).unwrap(), original);
        let mixed = format!("prefix\n{managed}suffix\r\n");
        assert_eq!(update(&mixed, None).unwrap(), "prefix\nsuffix\r\n");
    }
    #[test]
    fn unicode_lines_outside_managed_block_do_not_panic() {
        let original = "这些规则偏向谨慎而非速度。\n# User notes\n";
        let managed = block("vibeguard-runtime");
        assert!(!matches_block(original, &managed).unwrap());
        let installed = update(original, Some(&managed)).unwrap();
        assert_eq!(update(&installed, None).unwrap(), original);
    }
    #[test]
    fn examples_are_not_owned_blocks() {
        for original in [
            format!("````md\n{START}\n{END}\n````\nnotes"),
            format!("Example mentions {START} inline."),
            format!("~~~\n{START}\n{END}\n~~~"),
        ] {
            assert!(!matches_block(&original, &block("vibeguard-runtime")).unwrap());
            assert_eq!(update(&original, None).unwrap(), original);
        }
    }
    #[test]
    fn malformed_markers_fail_without_selecting_a_partial_block() {
        for original in [
            START.to_string(),
            END.to_string(),
            format!("{END}\n{START}\n"),
            format!("{START}\n{START}\n{END}\n"),
        ] {
            assert!(update(&original, Some("replacement")).is_err());
        }
    }
}
