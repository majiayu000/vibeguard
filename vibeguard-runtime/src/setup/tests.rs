use super::*;
#[test]
fn exec_handler_ownership_includes_arguments() {
    let ours =
        json!({"type":"command","command":"C:/runtime.exe","args":["hook","claude"],"timeout":10});
    let user = json!({"type":"command","command":"C:/runtime.exe","args":["rules"]});
    let mut config = json!({"hooks":{"PreToolUse":[{"hooks":[ours.clone(),user.clone()]}]}});
    assert!(hook_registrations(&config, &ours)[0]["selected_instance"] == true);
    assert!(hook_registrations(&config, &ours)[1]["selected_instance"] == false);
    prune_hooks(&mut config, &ours, false);
    assert_eq!(config["hooks"]["PreToolUse"][0]["hooks"], json!([user]));
}
#[test]
fn removal_preserves_unrelated_handlers_even_in_the_same_group() {
    let ours = "/path/to/runtime hook codex";
    let user =
        json!({"type":"command","command":"echo '/path/to/runtime hook codex'","custom":true});
    let mut config = json!({"unrelated":7,"hooks":{"PreToolUse":[{"matcher":"Bash","custom":"keep","hooks":[
        {"type":"command","command":ours},user.clone()
    ]}]}});
    validate_config(&config).unwrap();
    prune_hooks(&mut config, &json!({"command":ours}), false);
    assert_eq!(config["unrelated"], 7);
    assert_eq!(config["hooks"]["PreToolUse"][0]["custom"], "keep");
    assert_eq!(config["hooks"]["PreToolUse"][0]["hooks"], json!([user]));
}
#[test]
fn malformed_user_configuration_is_not_normalized_away() {
    for config in [
        json!([]),
        json!({"hooks":[]}),
        json!({"hooks":{"PreToolUse":{}}}),
        json!({"hooks":{"PreToolUse":[{"hooks":false}]}}),
    ] {
        assert!(validate_config(&config).is_err());
    }
}
