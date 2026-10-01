use crate::Result;
use std::ops::Range;

const START: &str = "<!-- vibeguard-core:start -->";
const END: &str = "<!-- vibeguard-core:end -->";

pub fn remove(original: &str) -> Result<String> {
    match region(original)? {
        Some(range) => {
            let mut result = original.to_string();
            result.replace_range(range, "");
            Ok(result)
        }
        None => Ok(original.to_string()),
    }
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
    fn preserves_exact_unmanaged_bytes() {
        let original = "# User notes\r\nCustom instruction without final newline";
        assert_eq!(remove(original).unwrap(), original);
        for managed in [
            format!("{START}\nPrevious core\n{END}\n"),
            format!("{START}\r\nPrevious core\r\n{END}\r\n"),
        ] {
            let installed = format!("{managed}{original}");
            assert_eq!(remove(&installed).unwrap(), original);
            let mixed = format!("prefix\n{managed}suffix\r\n");
            assert_eq!(remove(&mixed).unwrap(), "prefix\nsuffix\r\n");
        }
        assert_eq!(remove(&format!("{START}\n{END}")).unwrap(), "");
    }
    #[test]
    fn unicode_lines_outside_managed_block_do_not_panic() {
        let original = "这些规则偏向谨慎而非速度。\n# User notes\n";
        assert_eq!(remove(original).unwrap(), original);
        let installed = format!("{START}\nPrevious core\n{END}\n{original}");
        assert_eq!(remove(&installed).unwrap(), original);
    }
    #[test]
    fn examples_are_not_owned_blocks() {
        for original in [
            format!("````md\n{START}\n{END}\n````\nnotes"),
            format!("Example mentions {START} inline."),
            format!("~~~\n{START}\n{END}\n~~~"),
        ] {
            assert_eq!(remove(&original).unwrap(), original);
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
            assert!(remove(&original).is_err());
        }
    }
}
