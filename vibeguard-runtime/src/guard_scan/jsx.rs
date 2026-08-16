fn masked(character: char) -> char {
    if character == '\n' { '\n' } else { ' ' }
}

pub(super) fn mask_jsx_text(source: &str) -> String {
    let chars = source.chars().collect::<Vec<_>>();
    let mut output = String::with_capacity(source.len());
    let mut index = 0;
    let mut element_depth = 0usize;
    let mut in_text = false;
    while index < chars.len() {
        if chars[index] == '<'
            && looks_like_tag(&chars, index, in_text)
            && let Some(end) = tag_end(&chars, index)
        {
            let closing = chars.get(index + 1) == Some(&'/');
            let self_closing = chars[..end]
                .iter()
                .rposition(|character| !character.is_whitespace())
                .is_some_and(|position| chars[position] == '/');
            mask_tag(&chars, index, end, &mut output);
            if closing {
                element_depth = element_depth.saturating_sub(1);
            } else if !self_closing {
                element_depth += 1;
            }
            in_text = element_depth > 0;
            index = end + 1;
        } else if in_text && chars[index] == '{' {
            if let Some(end) = matching_jsx_expression_end(&chars, index) {
                output.push(' ');
                let expression = chars[index + 1..end].iter().collect::<String>();
                output.push_str(&mask_jsx_text(&expression));
                output.push(' ');
                index = end + 1;
            } else {
                output.push(masked(chars[index]));
                index += 1;
            }
        } else if in_text {
            output.push(masked(chars[index]));
            index += 1;
        } else {
            output.push(chars[index]);
            index += 1;
        }
    }
    output
}

fn looks_like_tag(chars: &[char], index: usize, in_text: bool) -> bool {
    let Some(next) = chars.get(index + 1).copied() else {
        return false;
    };
    if matches!(next, '>' | '/') {
        return true;
    }
    if !next.is_alphabetic() {
        return false;
    }
    if in_text {
        return true;
    }
    if looks_like_generic_arrow(chars, index) {
        return false;
    }
    let previous = chars[..index]
        .iter()
        .rposition(|character| !character.is_whitespace())
        .map(|position| chars[position]);
    previous.is_none_or(|character| {
        matches!(
            character,
            '=' | '>' | '(' | '[' | '{' | ',' | ':' | ';' | '!' | '&' | '|' | '?'
        )
    }) || chars[..index]
        .iter()
        .collect::<String>()
        .split_whitespace()
        .next_back()
        == Some("return")
}

fn looks_like_generic_arrow(chars: &[char], start: usize) -> bool {
    let Some(tag_end) = tag_end(chars, start) else {
        return false;
    };
    let mut index = skip_whitespace(chars, tag_end + 1);
    if chars.get(index) != Some(&'(') {
        return false;
    }
    let Some(parameters_end) = matching_parenthesis_end(chars, index) else {
        return false;
    };
    index = skip_whitespace(chars, parameters_end + 1);
    chars.get(index) == Some(&'=') && chars.get(index + 1) == Some(&'>')
}

fn skip_whitespace(chars: &[char], mut index: usize) -> usize {
    while chars
        .get(index)
        .is_some_and(|character| character.is_whitespace())
    {
        index += 1;
    }
    index
}

fn matching_parenthesis_end(chars: &[char], start: usize) -> Option<usize> {
    let mut depth = 0usize;
    let mut quote = None;
    let mut index = start;
    while index < chars.len() {
        let current = chars[index];
        if let Some(mark) = quote {
            if current == '\\' {
                index += 2;
                continue;
            }
            if current == mark {
                quote = None;
            }
        } else {
            match current {
                '\'' | '"' | '`' => quote = Some(current),
                '(' => depth += 1,
                ')' => {
                    depth = depth.saturating_sub(1);
                    if depth == 0 {
                        return Some(index);
                    }
                }
                _ => {}
            }
        }
        index += 1;
    }
    None
}

fn tag_end(chars: &[char], start: usize) -> Option<usize> {
    let mut quote = None;
    let mut braces = 0usize;
    let mut index = start + 1;
    while index < chars.len() {
        let current = chars[index];
        if let Some(mark) = quote {
            if current == '\\' {
                index += 2;
                continue;
            }
            if current == mark {
                quote = None;
            }
        } else {
            match current {
                '\'' | '"' => quote = Some(current),
                '{' => braces += 1,
                '}' => braces = braces.saturating_sub(1),
                '>' if braces == 0 => return Some(index),
                _ => {}
            }
        }
        index += 1;
    }
    None
}

fn mask_tag(chars: &[char], start: usize, end: usize, output: &mut String) {
    let mut index = start;
    while index <= end {
        if chars[index] == '{'
            && let Some(expression_end) = matching_jsx_expression_end(chars, index)
            && expression_end < end
        {
            output.push(' ');
            let expression = chars[index + 1..expression_end].iter().collect::<String>();
            output.push_str(&mask_jsx_text(&expression));
            output.push(' ');
            index = expression_end + 1;
        } else {
            output.push(masked(chars[index]));
            index += 1;
        }
    }
}

fn matching_jsx_expression_end(chars: &[char], start: usize) -> Option<usize> {
    let mut depth = 0usize;
    let mut quote = None;
    let mut line_comment = false;
    let mut block_comment = false;
    let mut index = start;
    while index < chars.len() {
        let current = chars[index];
        let next = chars.get(index + 1).copied();
        if line_comment {
            line_comment = current != '\n';
        } else if block_comment {
            if current == '*' && next == Some('/') {
                block_comment = false;
                index += 1;
            }
        } else if let Some(mark) = quote {
            if current == '\\' {
                index += 1;
            } else if current == mark {
                quote = None;
            }
        } else if current == '/' && next == Some('/') {
            line_comment = true;
            index += 1;
        } else if current == '/' && next == Some('*') {
            block_comment = true;
            index += 1;
        } else {
            match current {
                '\'' | '"' | '`' => quote = Some(current),
                '{' => depth += 1,
                '}' => {
                    depth = depth.saturating_sub(1);
                    if depth == 0 {
                        return Some(index);
                    }
                }
                _ => {}
            }
        }
        index += 1;
    }
    None
}
