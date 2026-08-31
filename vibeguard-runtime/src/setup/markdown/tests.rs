#[cfg(test)]
mod setup_markdown_tests {
    use super::super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn repo_dir() -> SetupResult<&'static Path> {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .ok_or_else(|| "vibeguard-runtime must be inside the repository".into())
    }

    #[test]
    fn replaces_marker_block() {
        let original = "a\n\n<!-- vibeguard-start -->\n# VibeGuard shared core\nold\n<!-- vibeguard-end -->\n\nb\n";
        let next = replace_managed_block(
            original,
            "<!-- vibeguard-start -->\n# VibeGuard shared core\nnew\n<!-- vibeguard-end -->",
        );
        assert!(next.contains("new"));
        assert!(!next.contains("old"));
        assert!(next.starts_with("a\n\n"));
        assert!(next.ends_with("b\n"));
    }

    #[test]
    fn inject_rejects_invalid_managed_source_without_changing_target() -> SetupResult<()> {
        let unique = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "vibeguard-setup-markdown-{}-{unique}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir)?;
        let target = dir.join("AGENTS.md");
        let source = dir.join("rules.md");
        let original = "user content\n";
        std::fs::write(&target, original)?;

        for invalid in [
            "outside\n<!-- vibeguard-start -->\n# VibeGuard shared core\nrules\n<!-- vibeguard-end -->\n",
            "<!-- vibeguard-start --> rules <!-- vibeguard-end -->\n",
            "<!-- vibeguard-start -->\n# VibeGuard shared core\nrules\n",
            "<!-- vibeguard-start -->\n# VibeGuard shared core\nrules\n<!-- vibeguard-end -->\n<!-- vibeguard-end -->\n",
            "<!-- vibeguard-start -->\nrules\n<!-- vibeguard-end -->\n",
        ] {
            std::fs::write(&source, invalid)?;
            assert!(
                inject(&[
                    target.display().to_string(),
                    source.display().to_string(),
                    dir.display().to_string(),
                    "127".to_string(),
                ])
                .is_err()
            );
            assert_eq!(std::fs::read_to_string(&target)?, original);
        }

        std::fs::remove_dir_all(dir)?;
        Ok(())
    }

    #[test]
    fn production_routing_placeholder_is_quoted_before_generic_replacement() -> SetupResult<()> {
        let unique = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "vibeguard-routing-placeholder-{}-{unique}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir)?;
        let target = dir.join("AGENTS.md");
        let rules = repo_dir()?.join("claude-md/vibeguard-codex-rules.md");
        let execution_root = "/tmp/Vibe Guard snapshot";

        let (_, _, content) = render_injected(&target, &rules, execution_root, "127")?;
        assert!(
            content.contains("`/tmp/Vibe Guard snapshot/workflows/references/routing-contract.md`")
        );
        assert!(
            !content
                .contains("at /tmp/Vibe Guard snapshot/workflows/references/routing-contract.md")
        );

        std::fs::remove_dir_all(dir)?;
        Ok(())
    }

    #[test]
    fn recognizes_and_replaces_released_legacy_heading() {
        let original = concat!(
            "user content\n\n",
            "<!-- vibeguard-start -->\n",
            "#VibeGuard — AI anti-hallucination rules\n",
            "old\n",
            "<!-- vibeguard-end -->\n",
        );
        let rules = concat!(
            "<!-- vibeguard-start -->\n",
            "# VibeGuard shared core\n",
            "new\n",
            "<!-- vibeguard-end -->",
        );
        assert!(marker_range(original).is_some());
        let next = replace_managed_block(original, rules);
        assert_eq!(next.matches(managed_block::START).count(), 1);
        assert!(next.contains(managed_block::MANAGED_HEADING));
        assert!(!next.contains(managed_block::LEGACY_MANAGED_HEADING));
    }

    #[test]
    fn ignores_prose_marker_pairs_without_anchor() {
        let original = concat!(
            "Do not paste <!-- vibeguard-start --> or <!-- vibeguard-end --> here.\n",
            "Keep this Codex-only section.\n",
        );
        let next = replace_managed_block(
            original,
            "<!-- vibeguard-start -->\n# VibeGuard shared core\nnew\n<!-- vibeguard-end -->",
        );
        assert_eq!(next, original);
        assert!(marker_range(original).is_none());
    }

    #[test]
    fn ignores_inline_markers_even_with_a_managed_heading_between_them() {
        let original = concat!(
            "Prose <!-- vibeguard-start -->\n",
            "# VibeGuard shared core\n",
            "more prose <!-- vibeguard-end -->\n",
        );
        assert!(marker_range(original).is_none());
        assert!(managed_blocks(original).is_empty());
    }

    #[test]
    fn ignores_managed_marker_examples_inside_code_fences() {
        for original in [
            concat!(
                "```markdown\n",
                "<!-- vibeguard-start -->\n",
                "# VibeGuard shared core\n",
                "example\n",
                "<!-- vibeguard-end -->\n",
                "```\n",
            ),
            concat!(
                "  ~~~~markdown\n",
                "<!-- vibeguard-start -->\n",
                "#VibeGuard — AI anti-hallucination rules\n",
                "example\n",
                "<!-- vibeguard-end -->\n",
                "  ~~~~\n",
            ),
        ] {
            assert!(marker_range(original).is_none());
            assert!(managed_blocks(original).is_empty());
        }
    }

    #[test]
    fn crlf_managed_boundaries_do_not_add_blank_lines() {
        let original = concat!(
            "Before\r\n\r\n",
            "<!-- vibeguard-start -->\r\n",
            "# VibeGuard shared core\r\n",
            "old\r\n",
            "<!-- vibeguard-end -->\r\n\r\n",
            "After\r\n",
        );
        let rules = concat!(
            "<!-- vibeguard-start -->\n",
            "# VibeGuard shared core\n",
            "new\n",
            "<!-- vibeguard-end -->",
        );
        assert_eq!(
            replace_managed_block(original, rules),
            concat!(
                "Before\n\n",
                "<!-- vibeguard-start -->\n",
                "# VibeGuard shared core\n",
                "new\n",
                "<!-- vibeguard-end -->\n\n",
                "After\r\n",
            )
        );
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
    fn profile_settings_reject_duplicate_managed_hooks() -> SetupResult<()> {
        let repo_dir = repo_dir()?;
        let core_specs = claude_specs(repo_dir, Some("core"))?;
        let pre_bash_spec = core_specs
            .iter()
            .find(|spec| spec.script == "pre-bash-guard.sh")
            .ok_or("expected pre-bash hook in core profile")?;

        let core_data = settings_data_with_specs(&core_specs);
        assert!(settings_has_profile_hooks(repo_dir, &core_data, "core")?);

        let mut duplicate_specs = core_specs.clone();
        duplicate_specs.push(pre_bash_spec.clone());
        let mut duplicate_data = settings_data_with_specs(&duplicate_specs);
        assert!(!settings_has_profile_hooks(
            repo_dir,
            &duplicate_data,
            "core"
        )?);

        let desired = core_specs.iter().map(settings_spec_identity).collect();
        assert!(settings_remove_unprofiled_hooks(
            repo_dir,
            &mut duplicate_data,
            &desired
        )?);
        assert!(settings_has_profile_hooks(
            repo_dir,
            &duplicate_data,
            "core"
        )?);
        Ok(())
    }

    #[test]
    fn profile_repair_preserves_unmanaged_hook_script_argument() -> SetupResult<()> {
        let repo_dir = repo_dir()?;
        let core_specs = claude_specs(repo_dir, Some("core"))?;
        let mut data = settings_data_with_specs(&core_specs);
        data["hooks"]["PostToolUse"]
            .as_array_mut()
            .expect("PostToolUse entries")
            .push(serde_json::json!({
                "matcher": "Edit",
                "hooks": [{
                    "type": "command",
                    "command": "node /custom/audit.js post-build-check.sh",
                }]
            }));

        assert!(settings_has_profile_hooks(repo_dir, &data, "core")?);
        let desired = core_specs.iter().map(settings_spec_identity).collect();
        assert!(!settings_remove_unprofiled_hooks(
            repo_dir, &mut data, &desired
        )?);
        assert!(
            serde_json::to_string(&data)?.contains("node /custom/audit.js post-build-check.sh")
        );
        Ok(())
    }

    #[test]
    fn profile_repair_preserves_unmanaged_wrapper_argument() -> SetupResult<()> {
        let repo_dir = repo_dir()?;
        let core_specs = claude_specs(repo_dir, Some("core"))?;
        let mut data = settings_data_with_specs(&core_specs);
        let command = "node /custom/audit.js /tmp/.vibeguard/run-hook.sh post-build-check.sh";
        data["hooks"]["PostToolUse"]
            .as_array_mut()
            .expect("PostToolUse entries")
            .push(serde_json::json!({
                "matcher": "Edit",
                "hooks": [{
                    "type": "command",
                    "command": command,
                }]
            }));

        assert!(settings_has_profile_hooks(repo_dir, &data, "core")?);
        let desired = core_specs.iter().map(settings_spec_identity).collect();
        assert!(!settings_remove_unprofiled_hooks(
            repo_dir, &mut data, &desired
        )?);
        assert!(serde_json::to_string(&data)?.contains(command));
        Ok(())
    }

    #[test]
    fn profile_repair_preserves_env_invoked_wrapper_customization() -> SetupResult<()> {
        let repo_dir = repo_dir()?;
        let core_specs = claude_specs(repo_dir, Some("core"))?;
        let pre_bash_spec = core_specs
            .iter()
            .find(|spec| spec.script == "pre-bash-guard.sh")
            .ok_or("expected pre-bash hook in core profile")?;
        let mut data = settings_data_with_specs(&core_specs);
        let command = "env VIBEGUARD_FOO=1 /tmp/.vibeguard/run-hook.sh pre-bash-guard.sh";
        let pre_tool_entries = data["hooks"]["PreToolUse"]
            .as_array_mut()
            .expect("PreToolUse entries");
        for entry in pre_tool_entries {
            if entry.get("matcher").and_then(Value::as_str) != Some("Bash") {
                continue;
            }
            entry["hooks"][0]["command"] = Value::String(command.to_string());
        }

        assert!(settings_has_profile_hooks(repo_dir, &data, "core")?);
        assert!(!settings_upsert_hook(&mut data, pre_bash_spec, false));
        let rendered = serde_json::to_string(&data)?;
        assert!(rendered.contains(command));
        assert_eq!(rendered.matches("pre-bash-guard.sh").count(), 1);
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
    fn canonical_settings_command_rejects_unquoted_home_spaces() {
        let command = "bash /tmp/home with spaces/.vibeguard/run-hook.sh pre-bash-guard.sh";
        assert!(!settings_is_canonical(command, "pre-bash-guard.sh"));
    }

    #[test]
    fn canonical_settings_command_rejects_custom_bash_options() {
        let command = "bash -x /tmp/workspace/.vibeguard/run-hook.sh pre-bash-guard.sh";
        assert!(!settings_is_canonical(command, "pre-bash-guard.sh"));
    }

    #[test]
    fn canonical_profile_rejects_direct_hook_scripts() -> SetupResult<()> {
        let repo_dir = repo_dir()?;
        let specs = claude_specs(repo_dir, Some("core"))?;
        let mut data = serde_json::json!({"hooks": {}});
        for spec in &specs {
            settings_upsert_hook(&mut data, spec, true);
        }
        assert!(settings_has_canonical_profile_hooks(
            repo_dir, &data, "core"
        )?);
        let command = data["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
            .as_str()
            .ok_or("expected command")?
            .replace(".vibeguard/run-hook.sh ", ".vibeguard/installed/hooks/");
        data["hooks"]["PreToolUse"][0]["hooks"][0]["command"] = Value::String(command);
        assert!(!settings_has_canonical_profile_hooks(
            repo_dir, &data, "core"
        )?);
        Ok(())
    }
}
