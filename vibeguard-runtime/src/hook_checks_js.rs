use regex::Regex;

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
    Regex::new(r"(?s)\bcatch\s*(?:\([^)]*\))?\s*\{\s*\}")
        .map(|regex| regex.find_iter(&code).count())
        .unwrap_or(0)
}

fn mask_javascript_non_code(source: &str) -> String {
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
            LexState::Code => {
                masked.push(current);
                if !current.is_whitespace() {
                    regex_can_start = !matches!(
                        current,
                        ')' | ']' | '}' | '.' | '_' | '$' | 'a'..='z' | 'A'..='Z' | '0'..='9'
                    );
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
                masked.push_str("  ");
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
        assert_eq!(empty_catch_count("const text = `catch {}`;"), 0);
        assert_eq!(
            empty_catch_count("const result = `${(() => { try { run(); } catch {} })()}`;"),
            1
        );
    }
}
