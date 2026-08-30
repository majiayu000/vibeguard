#![cfg(test)]

use super::*;

#[test]
fn hook_kind_accepts_short_and_script_names() {
    assert_eq!(HookKind::parse("pre-write"), Some(HookKind::PreWrite));
    assert_eq!(HookKind::parse("pre-write-guard"), Some(HookKind::PreWrite));
    assert_eq!(HookKind::parse("nope"), None);
}
