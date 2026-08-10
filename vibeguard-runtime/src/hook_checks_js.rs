use regex::Regex;

#[derive(Clone, Copy)]
enum LexState {
    Code,
    LineComment,
    BlockComment,
    Quoted(char),
}

pub(crate) fn empty_catch_count(source: &str) -> usize {
    let code = mask_javascript_non_code(source);
    Regex::new(r"(?s)\bcatch\s*(?:\([^)]*\))?\s*\{\s*\}")
        .map(|regex| regex.find_iter(&code).count())
        .unwrap_or(0)
}

fn mask_javascript_non_code(source: &str) -> String {
    let chars = source.chars().collect::<Vec<_>>();
    let mut masked = String::with_capacity(source.len());
    let mut state = LexState::Code;
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
            LexState::Code if matches!(current, '\'' | '"' | '`') => {
                masked.push(' ');
                state = LexState::Quoted(current);
                index += 1;
            }
            LexState::Code => {
                masked.push(current);
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
                masked.push_str("  ");
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
        }
    }
    masked
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
    }
}
