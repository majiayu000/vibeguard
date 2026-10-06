//! Copy into the completed error-propagation fixture's tests/ directory after the model run.
use limit_task::{parse_limit, read_limit};

#[test]
fn caller_preserves_valid_values_and_errors() {
    for (input, expected) in [
        (None, 10),
        (Some("0"), 0),
        (Some("23"), 23),
        (Some("4294967295"), u32::MAX),
    ] {
        assert_eq!(read_limit(input), Ok(expected));
    }
    for text in ["", "invalid", "-1", "4294967296"] {
        let input = Some(text);
        let parser_error = parse_limit(input).expect_err("fixture parser must reject this input");
        assert_eq!(read_limit(input), Err(parser_error));
    }
}
