use std::collections::HashMap;

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
    catch_clauses(source)
        .iter()
        .filter(|clause| clause.empty)
        .count()
}

pub(crate) fn introduced_empty_catch_count(old_source: &str, new_source: &str) -> usize {
    if old_source.is_empty() {
        return empty_catch_count(new_source);
    }
    let old_chars: Vec<_> = old_source.chars().collect();
    let new_chars: Vec<_> = new_source.chars().collect();
    let prefix = old_chars
        .iter()
        .zip(&new_chars)
        .take_while(|(a, b)| a == b)
        .count();
    let suffix = old_chars[prefix..]
        .iter()
        .rev()
        .zip(new_chars[prefix..].iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    // Preserve untouched handlers; correlate edited ones by try-body identity plus
    // preceding context so duplicate try bodies do not share one FIFO queue.
    let old_edited: Vec<_> = catch_clauses(old_source)
        .into_iter()
        .filter(|clause| clause.end > prefix && clause.start < old_chars.len() - suffix)
        .collect();
    let mut unmatched_old: Vec<Option<CatchClause>> =
        old_edited.into_iter().map(Some).collect();
    catch_clauses(new_source)
        .into_iter()
        .filter(|clause| clause.end > prefix && clause.start < new_chars.len() - suffix)
        .filter(|clause| {
            if !clause.empty {
                // Still consume the best prior match so later empties stay aligned.
                let _ = take_best_prior_match(&mut unmatched_old, clause, &old_chars);
                return false;
            }
            let was_empty = take_best_prior_match(&mut unmatched_old, clause, &old_chars)
                .map(|prior| prior.empty);
            was_empty != Some(true)
        })
        .count()
}

fn take_best_prior_match(
    unmatched_old: &mut [Option<CatchClause>],
    new_clause: &CatchClause,
    old_chars: &[char],
) -> Option<CatchClause> {
    let mut best: Option<(usize, i64)> = None;
    for (index, candidate) in unmatched_old.iter().enumerate() {
        let Some(old_clause) = candidate.as_ref() else {
            continue;
        };
        let score = clause_match_score(old_clause, new_clause, old_chars);
        if best.is_none_or(|(_, best_score)| score > best_score) {
            best = Some((index, score));
        }
    }
    let (index, score) = best?;
    if score < 0 {
        return None;
    }
    unmatched_old[index].take()
}

fn clause_match_score(old_clause: &CatchClause, new_clause: &CatchClause, old_chars: &[char]) -> i64 {
    let context_score = shared_suffix_len(
        &preceding_context(old_chars, old_clause.try_start),
        &new_clause.preceding,
    ) as i64;
    let identity_bonus = i64::from(old_clause.identity == new_clause.identity) * 64;
    let distance = (old_clause.start as i64 - new_clause.start as i64).abs();
    identity_bonus + context_score * 4 - distance
}

fn preceding_context(chars: &[char], try_start: usize) -> String {
    let start = try_start.saturating_sub(48);
    chars[start..try_start].iter().collect()
}

fn shared_suffix_len(left: &str, right: &str) -> usize {
    left.chars()
        .rev()
        .zip(right.chars().rev())
        .take_while(|(a, b)| a == b)
        .count()
}

struct CatchClause {
    identity: String,
    preceding: String,
    try_start: usize,
    start: usize,
    end: usize,
    empty: bool,
}

fn catch_clauses(source: &str) -> Vec<CatchClause> {
    let code = mask_javascript_non_code(source);
    let chars = code.chars().collect::<Vec<_>>();
    let original = source.chars().collect::<Vec<_>>();
    let try_closings = try_block_closing_braces(&chars);
    let mut clauses = Vec::new();
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
        if chars[start..index].iter().collect::<String>() != "catch" {
            continue;
        }
        let Some(try_close) = previous_non_whitespace_index(&chars, start) else {
            continue;
        };
        let Some(&try_start) = try_closings.get(&try_close) else {
            continue;
        };
        let mut cursor = skip_whitespace(&chars, index);
        if chars.get(cursor) == Some(&'(') {
            let Some(binding_end) = balanced_end(&chars, cursor, '(', ')') else {
                continue;
            };
            cursor = skip_whitespace(&chars, binding_end);
        }
        if chars.get(cursor) != Some(&'{') {
            continue;
        }
        let Some(end) = balanced_end(&chars, cursor, '{', '}') else {
            continue;
        };
        // Identity is the try block only so binding-only renames of an already-empty
        // handler (catch (error) {} → catch {} / catch (e) {}) stay matched.
        // preceding context disambiguates duplicate try bodies across handlers.
        clauses.push(CatchClause {
            identity: original[try_start..=try_close].iter().collect(),
            preceding: preceding_context(&original, try_start),
            try_start,
            start,
            end,
            empty: chars.get(skip_whitespace(&chars, cursor + 1)) == Some(&'}'),
        });
    }
    clauses
}

fn try_block_closing_braces(chars: &[char]) -> HashMap<usize, usize> {
    let mut closings = HashMap::new();
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
                blocks.push(pending_try.then_some(index));
                pending_try = false;
            }
            '}' => {
                if let Some(Some(start)) = blocks.pop() {
                    closings.insert(index, start);
                }
                pending_try = false;
            }
            _ => pending_try = false,
        }
        index += 1;
    }
    closings
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
    let mut pending_control_condition = false;
    let mut control_condition_parens = Vec::new();
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
                pending_control_condition =
                    matches!(token.as_str(), "if" | "for" | "while" | "with");
            }
            LexState::Code if matches!(current, '+' | '-') && next == Some(current) => {
                masked.push(current);
                masked.push(current);
                index += 2;
            }
            LexState::Code if current == '!' && next != Some('=') && !regex_can_start => {
                masked.push(current);
                index += 1;
            }
            LexState::Code if current == '(' => {
                masked.push(current);
                control_condition_parens.push(pending_control_condition);
                pending_control_condition = false;
                regex_can_start = true;
                index += 1;
            }
            LexState::Code if current == ')' => {
                masked.push(current);
                regex_can_start = control_condition_parens.pop().unwrap_or(false);
                pending_control_condition = false;
                index += 1;
            }
            LexState::Code => {
                masked.push(current);
                if !current.is_whitespace() {
                    regex_can_start = !matches!(current, ')' | ']' | '}' | '.' | '0'..='9');
                    pending_control_condition = false;
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
                regex_can_start = false;
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
    fn catches_are_compared_independently_of_other_handlers() {
        let old = "try { first(); } catch {}\ntry { second(); } catch (e) { report(e); }";
        for new in [
            "try { first(); } catch { report(); }\ntry { second(); } catch (e) {}",
            "try { second(); } catch (e) {}",
        ] {
            assert_eq!(introduced_empty_catch_count(old, new), 1);
        }
        assert_eq!(
            introduced_empty_catch_count(
                "try { first(); } catch {}\ntry { second(); } catch {}",
                "try { second(); } catch {}",
            ),
            0
        );
        assert_eq!(
            introduced_empty_catch_count(
                "try { run(\"first\"); } catch {}\ntry { run(\"second\"); } catch { report(); }",
                "try { run(\"second\"); } catch {}",
            ),
            1
        );
        assert_eq!(
            introduced_empty_catch_count(
                "try { first(); } catch {}",
                "try { changed(); } catch {}",
            ),
            0
        );
        assert_eq!(
            introduced_empty_catch_count(
                "try { run(); } catch (error) {}",
                "try { run(); } catch {}",
            ),
            0
        );
        assert_eq!(
            introduced_empty_catch_count(
                "try { run(); } catch (error) {}",
                "try { run(); } catch (e) {}",
            ),
            0
        );
        assert_eq!(
            introduced_empty_catch_count(
                "function a(){try{run()}catch{}} function b(){try{run()}catch{report()}}",
                "function b(){try{run()}catch{}}",
            ),
            1
        );
        assert_eq!(
            introduced_empty_catch_count(
                "function a(){try{run()}catch{}} function b(){try{run()}catch{report()}}",
                "function a(){try{run()}catch{}}",
            ),
            0
        );
    }

    #[test]
    fn empty_catches_are_code_aware() {
        assert_eq!(
            introduced_empty_catch_count(
                "try { run(); } catch (error) {}\nconst ready = true;\n",
                "try { run(); } catch (error) {}\nconst ready = false;\n",
            ),
            0
        );
        assert_eq!(
            introduced_empty_catch_count(
                "const ready = true;\n",
                "try { run(); } catch (error) {}\nconst ready = true;\n",
            ),
            1
        );
        assert_eq!(
            introduced_empty_catch_count(
                "try { run(); } catch (error) { report(error); }\n",
                "try { run(); } catch (error) {}\n",
            ),
            1
        );
        assert_eq!(
            introduced_empty_catch_count(
                "try { run(); } catch (error) {}\n",
                "try { run(); } catch (error) { report(error); }\n",
            ),
            0
        );
        assert_eq!(
            introduced_empty_catch_count(
                "class C { catch (error) { report(error); } }",
                "class C { catch (error) {} }",
            ),
            0
        );
        assert_eq!(
            introduced_empty_catch_count(
                "const c = { catch (error) { report(error); } };",
                "const c = { catch (error) {} };",
            ),
            0
        );
        assert_eq!(
            introduced_empty_catch_count("catch (error) {}", "catch (error) { report(error); }"),
            0
        );
        assert_eq!(empty_catch_count("foo() {} catch (error) {}"), 0);
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
