use std::collections::HashSet;

#[derive(Clone, Copy)]
enum LexState {
    Code,
    LineComment,
    BlockComment,
    Quoted(char),
    Regex { in_character_class: bool },
    Template,
}

pub(crate) fn empty_catch_count(source: &str) -> usize {
    let code = mask_javascript_non_code(source);
    count_empty_catch_clauses(&code)
}

fn count_empty_catch_clauses(code: &str) -> usize {
    let chars = code.chars().collect::<Vec<_>>();
    let try_closings = try_block_closing_braces(&chars);
    let mut count = 0;
    let mut index = 0;
    while index < chars.len() {
        if !is_identifier_start(chars[index]) {
            index += 1;
            continue;
        }
        let start = index;
        index += 1;
        while index < chars.len() && is_identifier_continue(chars[index]) {
            index += 1;
        }
        if chars[start..index].iter().collect::<String>() == "catch"
            && is_empty_catch_clause(&chars, &try_closings, start, index)
        {
            count += 1;
        }
    }
    count
}

fn try_block_closing_braces(chars: &[char]) -> HashSet<usize> {
    let mut closings = HashSet::new();
    let mut blocks = Vec::new();
    let mut pending_try = false;
    let mut index = 0;
    while index < chars.len() {
        if chars[index].is_whitespace() {
            index += 1;
            continue;
        }
        if is_identifier_start(chars[index]) {
            let start = index;
            index += 1;
            while index < chars.len() && is_identifier_continue(chars[index]) {
                index += 1;
            }
            pending_try = chars[start..index].iter().collect::<String>() == "try";
            continue;
        }
        match chars[index] {
            '{' => {
                blocks.push(pending_try);
                pending_try = false;
            }
            '}' => {
                if blocks.pop() == Some(true) {
                    closings.insert(index);
                }
                pending_try = false;
            }
            _ => pending_try = false,
        }
        index += 1;
    }
    closings
}

fn is_empty_catch_clause(
    chars: &[char],
    try_closings: &HashSet<usize>,
    start: usize,
    end: usize,
) -> bool {
    let Some(previous) = previous_non_whitespace_index(chars, start) else {
        return false;
    };
    if !try_closings.contains(&previous) {
        return false;
    }

    let mut cursor = skip_whitespace(chars, end);
    if chars.get(cursor) == Some(&'(') {
        let Some(binding_end) = balanced_end(chars, cursor, '(', ')') else {
            return false;
        };
        cursor = skip_whitespace(chars, binding_end);
    }
    if chars.get(cursor) != Some(&'{') {
        return false;
    }
    cursor = skip_whitespace(chars, cursor + 1);
    chars.get(cursor) == Some(&'}')
}

fn previous_non_whitespace_index(chars: &[char], before: usize) -> Option<usize> {
    chars[..before]
        .iter()
        .rposition(|character| !character.is_whitespace())
}

fn skip_whitespace(chars: &[char], mut index: usize) -> usize {
    while chars.get(index).is_some_and(|value| value.is_whitespace()) {
        index += 1;
    }
    index
}

fn balanced_end(chars: &[char], start: usize, open: char, close: char) -> Option<usize> {
    let mut depth = 0;
    for (offset, character) in chars[start..].iter().copied().enumerate() {
        if character == open {
            depth += 1;
        } else if character == close {
            depth -= 1;
            if depth == 0 {
                return Some(start + offset + 1);
            }
        }
    }
    None
}

fn is_identifier_start(character: char) -> bool {
    character == '_' || character == '$' || character.is_alphabetic()
}

fn is_identifier_continue(character: char) -> bool {
    is_identifier_start(character) || character.is_ascii_digit()
}

fn keyword_allows_regex_after(token: &str) -> bool {
    matches!(
        token,
        "await"
            | "case"
            | "delete"
            | "do"
            | "else"
            | "in"
            | "instanceof"
            | "new"
            | "of"
            | "return"
            | "throw"
            | "typeof"
            | "void"
            | "yield"
    )
}

pub(crate) fn mask_javascript_non_code(source: &str) -> String {
    let chars = source.chars().collect::<Vec<_>>();
    let mut masked = String::with_capacity(source.len());
    let mut state = LexState::Code;
    let mut template_expression_depths: Vec<usize> = Vec::new();
    let mut regex_can_start = true;
    let mut index = 0;
    while index < chars.len() {
        let current = chars[index];
        let next = chars.get(index + 1).copied();
        match state {
            LexState::Code if current == '/' && next == Some('/') => {
                masked.push_str("  ");
                state = LexState::LineComment;
                index += 2;
            }
            LexState::Code if current == '/' && next == Some('*') => {
                masked.push_str("  ");
                state = LexState::BlockComment;
                index += 2;
            }
            LexState::Code if current == '/' && regex_can_start => {
                masked.push(' ');
                state = LexState::Regex {
                    in_character_class: false,
                };
                index += 1;
            }
            LexState::Code if matches!(current, '\'' | '"') => {
                masked.push(' ');
                state = LexState::Quoted(current);
                index += 1;
            }
            LexState::Code if current == '`' => {
                masked.push(' ');
                state = LexState::Template;
                index += 1;
            }
            LexState::Code if current == '{' && !template_expression_depths.is_empty() => {
                if let Some(depth) = template_expression_depths.last_mut() {
                    *depth += 1;
                }
                masked.push(current);
                regex_can_start = true;
                index += 1;
            }
            LexState::Code if current == '}' && !template_expression_depths.is_empty() => {
                let mut resumes_template = false;
                if let Some(depth) = template_expression_depths.last_mut() {
                    *depth = depth.saturating_sub(1);
                    resumes_template = *depth == 0;
                }
                masked.push(current);
                regex_can_start = false;
                index += 1;
                if resumes_template {
                    template_expression_depths.pop();
                    state = LexState::Template;
                }
            }
            LexState::Code if is_identifier_start(current) => {
                let start = index;
                index += 1;
                while index < chars.len() && is_identifier_continue(chars[index]) {
                    index += 1;
                }
                let token = chars[start..index].iter().collect::<String>();
                masked.push_str(&token);
                regex_can_start = keyword_allows_regex_after(&token);
            }
            LexState::Code if matches!(current, '+' | '-') && next == Some(current) => {
                masked.push(current);
                masked.push(current);
                index += 2;
            }
            LexState::Code => {
                masked.push(current);
                if !current.is_whitespace() {
                    regex_can_start = !matches!(current, ')' | ']' | '}' | '.' | '0'..='9');
                }
                index += 1;
            }
            LexState::LineComment if current == '\n' => {
                masked.push('\n');
                state = LexState::Code;
                index += 1;
            }
            LexState::LineComment => {
                masked.push(' ');
                index += 1;
            }
            LexState::BlockComment if current == '*' && next == Some('/') => {
                masked.push_str("  ");
                state = LexState::Code;
                index += 2;
            }
            LexState::BlockComment => {
                masked.push(if current == '\n' { '\n' } else { ' ' });
                index += 1;
            }
            LexState::Quoted(_) if current == '\\' && next.is_some() => {
                push_masked_escape(&mut masked, next);
                index += 2;
            }
            LexState::Quoted(quote) if current == quote => {
                masked.push(' ');
                state = LexState::Code;
                index += 1;
            }
            LexState::Quoted(_) => {
                masked.push(if current == '\n' { '\n' } else { ' ' });
                index += 1;
            }
            LexState::Regex { .. } if current == '\\' && next.is_some() => {
                masked.push_str("  ");
                index += 2;
            }
            LexState::Regex {
                in_character_class: false,
            } if current == '[' => {
                masked.push(' ');
                state = LexState::Regex {
                    in_character_class: true,
                };
                index += 1;
            }
            LexState::Regex {
                in_character_class: true,
            } if current == ']' => {
                masked.push(' ');
                state = LexState::Regex {
                    in_character_class: false,
                };
                index += 1;
            }
            LexState::Regex {
                in_character_class: false,
            } if current == '/' => {
                masked.push(' ');
                state = LexState::Code;
                regex_can_start = false;
                index += 1;
            }
            LexState::Regex { .. } => {
                masked.push(if current == '\n' { '\n' } else { ' ' });
                index += 1;
            }
            LexState::Template if current == '\\' && next.is_some() => {
                push_masked_escape(&mut masked, next);
                index += 2;
            }
            LexState::Template if current == '$' && next == Some('{') => {
                masked.push_str(" {");
                template_expression_depths.push(1);
                state = LexState::Code;
                regex_can_start = true;
                index += 2;
            }
            LexState::Template if current == '`' => {
                masked.push(' ');
                state = LexState::Code;
                regex_can_start = false;
                index += 1;
            }
            LexState::Template => {
                masked.push(if current == '\n' { '\n' } else { ' ' });
                index += 1;
            }
        }
    }
    masked
}

fn push_masked_escape(masked: &mut String, next: Option<char>) {
    masked.push(' ');
    masked.push(if next == Some('\n') { '\n' } else { ' ' });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_catches_are_code_aware() {
        assert_eq!(empty_catch_count("try { run(); } catch (error) {}"), 1);
        assert_eq!(empty_catch_count("try { run(); } catch {}"), 1);
        assert_eq!(empty_catch_count("try { run(); } catch { report(); }"), 0);
        assert_eq!(
            empty_catch_count("const text = 'catch (e) {}'; // catch {}\n/* catch {} */"),
            0
        );
        assert_eq!(empty_catch_count(r"const matcher = /catch\s*\{\}/;"), 0);
        assert_eq!(
            empty_catch_count("function matcher() { return /catch {}/; }"),
            0
        );
        assert_eq!(empty_catch_count("const text = `catch {}`;"), 0);
        assert_eq!(
            empty_catch_count("const result = `${(() => { try { run(); } catch {} })()}`;"),
            1
        );
        assert_eq!(
            empty_catch_count("try { run(); } catch ({[String('x')]: value}) {}"),
            1
        );
        assert_eq!(empty_catch_count("class Cache { catch() {} }"), 0);
        assert_eq!(
            empty_catch_count("const handlers = { catch(error) {} };"),
            0
        );
        assert_eq!(empty_catch_count("class Cache { get() {} catch() {} }"), 0);
    }
}
