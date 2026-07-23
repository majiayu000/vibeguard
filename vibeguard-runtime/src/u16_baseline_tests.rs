use super::*;

#[test]
fn u16_baseline_decision_matrix_matches_legacy_policy() {
    assert_eq!(
        evaluate_u16_baseline(false, 0, 801, 800),
        U16BaselineDecision::Block(U16BlockReason::NewOversized)
    );
    assert_eq!(
        evaluate_u16_baseline(true, 799, 801, 800),
        U16BaselineDecision::Block(U16BlockReason::CrossesLimit)
    );
    assert_eq!(
        evaluate_u16_baseline(true, 1463, 1464, 800),
        U16BaselineDecision::Block(U16BlockReason::LegacyGrowth)
    );
    assert_eq!(
        evaluate_u16_baseline(true, 1463, 1463, 800),
        U16BaselineDecision::LegacyDebt
    );
    assert_eq!(
        evaluate_u16_baseline(true, 1463, 1200, 800),
        U16BaselineDecision::LegacyDebt
    );
    assert_eq!(
        evaluate_u16_baseline(true, 1463, 799, 800),
        U16BaselineDecision::Allow
    );
}

#[test]
fn u16_baseline_respects_explicit_limit() {
    assert_eq!(
        evaluate_u16_baseline(false, 0, 1200, 1500),
        U16BaselineDecision::Allow
    );
}
