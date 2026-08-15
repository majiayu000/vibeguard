use crate::setup::support::SetupResult;

pub(super) const START: &str = "<!-- vibeguard-start -->";
pub(super) const END: &str = "<!-- vibeguard-end -->";
pub(super) const MANAGED_HEADING: &str = "# VibeGuard shared core";
pub(super) const LEGACY_MANAGED_HEADING: &str = "#VibeGuard — AI anti-hallucination rules";

pub(super) fn validate_managed_source(text: &str) -> SetupResult<()> {
    if text.matches(START).count() != 1 || text.matches(END).count() != 1 {
        return Err("managed source must contain exactly one VibeGuard marker pair".into());
    }
    if !text.lines().any(|line| line == START) || !text.lines().any(|line| line == END) {
        return Err("managed source markers must appear on standalone lines".into());
    }
    if !text.lines().any(|line| line == MANAGED_HEADING) {
        return Err(format!("managed source must contain heading: {MANAGED_HEADING}").into());
    }
    let start = text.find(START).expect("validated start marker count");
    let end = text[start + START.len()..]
        .find(END)
        .map(|offset| start + START.len() + offset)
        .ok_or("managed source end marker must follow its start marker")?;
    if !text[..start].trim().is_empty() || !text[end + END.len()..].trim().is_empty() {
        return Err("managed source must not contain content outside its marker pair".into());
    }
    Ok(())
}

pub(super) fn replace_managed_block(original: &str, rules: &str) -> String {
    let Some((start, end_after)) = marker_range(original) else {
        return original.to_string();
    };
    let before = original[..start].trim_end();
    let after = original[end_after..].trim_start_matches(['\r', '\n']);
    let mut content = String::new();
    if !before.is_empty() {
        content.push_str(before);
        content.push_str("\n\n");
    }
    content.push_str(rules.trim());
    content.push('\n');
    if !after.is_empty() {
        content.push('\n');
        content.push_str(after);
    }
    content
}

pub(super) fn marker_range(text: &str) -> Option<(usize, usize)> {
    managed_blocks(text).into_iter().next()
}

pub(super) fn managed_blocks(text: &str) -> Vec<(usize, usize)> {
    let starts = standalone_line_ranges(text, START);
    let ends = standalone_line_ranges(text, END);
    let headings = [MANAGED_HEADING, LEGACY_MANAGED_HEADING]
        .into_iter()
        .flat_map(|heading| standalone_line_ranges(text, heading))
        .collect::<Vec<_>>();
    let mut blocks = Vec::new();
    for (index, (start, start_after)) in starts.iter().copied().enumerate() {
        let next_start = starts.get(index + 1).map(|(next, _)| *next);
        let Some((end, end_after)) = ends.iter().copied().find(|(end, _)| *end >= start_after)
        else {
            continue;
        };
        if next_start.is_some_and(|next| next < end) {
            continue;
        }
        if headings
            .iter()
            .any(|(heading, _)| *heading >= start_after && *heading < end)
        {
            blocks.push((start, end_after));
        }
    }
    blocks
}

fn standalone_line_ranges(text: &str, expected: &str) -> Vec<(usize, usize)> {
    let mut ranges = Vec::new();
    let mut offset = 0;
    for segment in text.split_inclusive('\n') {
        let without_lf = segment.strip_suffix('\n').unwrap_or(segment);
        let line = without_lf.strip_suffix('\r').unwrap_or(without_lf);
        if line == expected {
            ranges.push((offset, offset + segment.len()));
        }
        offset += segment.len();
    }
    ranges
}
