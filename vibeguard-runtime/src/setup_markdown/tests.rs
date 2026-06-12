#[cfg(test)]
mod setup_markdown_tests {
    use super::super::*;

    fn repo_dir() -> SetupResult<&'static Path> {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .ok_or_else(|| "vibeguard-runtime must be inside the repository".into())
    }

    #[test]
    fn replaces_marker_block() {
        let original = "a\n\n<!-- vibeguard-start -->\nold\n<!-- vibeguard-end -->\n\nb\n";
        let next = replace_managed_block(
            original,
            "<!-- vibeguard-start -->\nnew\n<!-- vibeguard-end -->",
        );
        assert!(next.contains("new"));
        assert!(!next.contains("old"));
        assert!(next.starts_with("a\n\n"));
        assert!(next.ends_with("b\n"));
    }

    #[test]
    fn profile_settings_reject_out_of_profile_managed_hooks() -> SetupResult<()> {
        let repo_dir = repo_dir()?;
        let core_specs = claude_specs(repo_dir, Some("core"))?;
        let extra_spec = claude_specs(repo_dir, None)?
            .into_iter()
            .find(|spec| {
                !core_specs
                    .iter()
                    .any(|desired| desired.event == spec.event && desired.script == spec.script)
            })
            .ok_or("expected an out-of-profile managed hook spec")?;

        let core_data = settings_data_with_specs(&core_specs);
        assert!(settings_has_profile_hooks(repo_dir, &core_data, "core")?);

        let mut stale_specs = core_specs;
        stale_specs.push(extra_spec);
        let stale_data = settings_data_with_specs(&stale_specs);
        assert!(!settings_has_profile_hooks(repo_dir, &stale_data, "core")?);
        Ok(())
    }

    #[test]
    fn profile_repair_removes_same_script_wrong_matcher() -> SetupResult<()> {
        let repo_dir = repo_dir()?;
        let core_specs = claude_specs(repo_dir, Some("core"))?;
        let analysis_spec = core_specs
            .iter()
            .find(|spec| spec.script == "analysis-paralysis-guard.sh")
            .ok_or("expected analysis-paralysis hook in core profile")?;
        let mut data = settings_data_with_specs(&core_specs);
        data["hooks"]["PostToolUse"]
            .as_array_mut()
            .expect("PostToolUse entries")
            .push(serde_json::json!({
                "matcher": "Bash",
                "hooks": [{
                    "type": "command",
                    "command": format!("bash /tmp/.vibeguard/run-hook.sh {}", analysis_spec.script),
                }]
            }));

        assert!(!settings_has_profile_hooks(repo_dir, &data, "core")?);
        let desired = core_specs.iter().map(settings_spec_identity).collect();
        assert!(settings_remove_unprofiled_hooks(
            repo_dir, &mut data, &desired
        )?);
        assert!(settings_has_profile_hooks(repo_dir, &data, "core")?);
        Ok(())
    }

    fn settings_data_with_specs(specs: &[ClaudeSpec]) -> Value {
        let mut data = serde_json::json!({"hooks": {}});
        let hooks = data
            .get_mut("hooks")
            .and_then(Value::as_object_mut)
            .expect("hooks object");
        for spec in specs {
            let entries = hooks
                .entry(spec.event.clone())
                .or_insert_with(|| serde_json::json!([]))
                .as_array_mut()
                .expect("event entries");
            let mut entry = serde_json::json!({
                "hooks": [{
                    "type": "command",
                    "command": format!("bash /tmp/.vibeguard/run-hook.sh {}", spec.script),
                }]
            });
            if !spec.matcher.is_empty() {
                entry
                    .as_object_mut()
                    .expect("entry object")
                    .insert("matcher".to_string(), Value::String(spec.matcher.clone()));
            }
            entries.push(entry);
        }
        data
    }

    #[test]
    fn canonical_settings_command_accepts_legacy_unquoted_home_spaces() {
        let command = "bash /tmp/home with spaces/.vibeguard/run-hook.sh pre-bash-guard.sh";
        assert!(settings_is_canonical(command, "pre-bash-guard.sh"));
    }

    #[test]
    fn canonical_settings_command_rejects_custom_bash_options() {
        let command = "bash -x /tmp/workspace/.vibeguard/run-hook.sh pre-bash-guard.sh";
        assert!(!settings_is_canonical(command, "pre-bash-guard.sh"));
    }
}
