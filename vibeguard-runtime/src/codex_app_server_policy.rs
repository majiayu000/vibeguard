use crate::project_config::{load_project_config, project_config_path};
use serde_json::Value;
use std::collections::HashMap;
use std::path::Path;

const HOOKS_MANIFEST_JSON: &str = include_str!("../../hooks/manifest.json");

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookPolicyDecision {
    Run {
        warn_mode: bool,
        reason: Option<String>,
    },
    Skip(String),
    Error(String),
}

pub fn evaluate_hook_policy(
    hook_name: &str,
    cwd: Option<&str>,
    env_overrides: &HashMap<String, String>,
) -> HookPolicyDecision {
    let Some(path) = project_config_path(cwd, env_overrides) else {
        return HookPolicyDecision::Run {
            warn_mode: false,
            reason: None,
        };
    };

    let config = match load_project_config(&path) {
        Ok(config) => config,
        Err(reason) => return HookPolicyDecision::Error(reason),
    };

    let canonical_hook = app_server_canonical_hook_name(hook_name);
    let enforcement = config.enforcement.as_deref().unwrap_or("block");
    if enforcement == "off" {
        return HookPolicyDecision::Skip("VibeGuard policy skip: enforcement=off".into());
    }

    if config
        .disabled_hooks
        .iter()
        .any(|hook| hook == &canonical_hook)
    {
        return HookPolicyDecision::Skip(format!(
            "VibeGuard policy skip: disabled_hooks contains {canonical_hook}"
        ));
    }

    let profile = config.profile.as_deref().unwrap_or("core");
    let profile_allowed = match manifest_profile_allows_hook(profile, &canonical_hook) {
        Ok(allowed) => allowed,
        Err(reason) => return HookPolicyDecision::Error(reason),
    };
    if !profile_allowed {
        return HookPolicyDecision::Skip(format!(
            "VibeGuard policy skip: profile={profile} excludes {canonical_hook}"
        ));
    }

    if enforcement == "warn" {
        return HookPolicyDecision::Run {
            warn_mode: true,
            reason: Some("VibeGuard policy warn: enforcement=warn".into()),
        };
    }

    HookPolicyDecision::Run {
        warn_mode: false,
        reason: None,
    }
}

pub fn required_hook_missing_message(hook_name: &str, hook_path: &Path) -> Option<String> {
    if matches!(
        app_server_canonical_hook_name(hook_name).as_str(),
        "pre-bash-guard" | "pre-edit-guard" | "pre-write-guard"
    ) {
        return Some(format!(
            "VIBEGUARD install incomplete: missing required hook {hook_name} at {}",
            hook_path.display()
        ));
    }
    None
}

fn app_server_canonical_hook_name(hook_name: &str) -> String {
    let file = Path::new(hook_name)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(hook_name);
    file.strip_suffix(".sh")
        .unwrap_or(file)
        .strip_prefix("vibeguard-")
        .unwrap_or_else(|| file.strip_suffix(".sh").unwrap_or(file))
        .replace('_', "-")
}

fn manifest_profile_allows_hook(profile: &str, hook_name: &str) -> Result<bool, String> {
    let Some((_, profiles)) = manifest_hook_profiles()?
        .into_iter()
        .find(|(name, _)| name == hook_name)
    else {
        return Ok(true);
    };

    Ok(profiles.iter().any(|candidate| candidate == profile))
}

#[cfg(test)]
fn manifest_profiles() -> Result<Vec<String>, String> {
    let manifest = serde_json::from_str::<Value>(HOOKS_MANIFEST_JSON)
        .map_err(|err| format!("hooks/manifest.json invalid JSON: {err}"))?;
    manifest
        .get("profiles")
        .and_then(Value::as_array)
        .ok_or_else(|| "hooks/manifest.json missing profiles array".to_string())?
        .iter()
        .map(|profile| {
            profile
                .as_str()
                .map(str::to_string)
                .ok_or_else(|| "hooks/manifest.json profiles contains non-string".to_string())
        })
        .collect()
}

fn manifest_hook_profiles() -> Result<Vec<(String, Vec<String>)>, String> {
    let manifest = serde_json::from_str::<Value>(HOOKS_MANIFEST_JSON)
        .map_err(|err| format!("hooks/manifest.json invalid JSON: {err}"))?;
    let hooks = manifest
        .get("hooks")
        .and_then(Value::as_array)
        .ok_or_else(|| "hooks/manifest.json missing hooks array".to_string())?;

    let mut entries = Vec::new();
    for hook in hooks {
        let name = hook
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| "hooks/manifest.json hook entry missing string name".to_string())?;
        let Some(profiles_value) = hook
            .get("claude")
            .and_then(Value::as_object)
            .and_then(|claude| claude.get("profiles"))
        else {
            continue;
        };
        let profiles = profiles_value
            .as_array()
            .ok_or_else(|| {
                format!("hooks/manifest.json hook {name} claude.profiles must be a list")
            })?
            .iter()
            .map(|profile| {
                profile.as_str().map(str::to_string).ok_or_else(|| {
                    format!("hooks/manifest.json hook {name} claude.profiles contains non-string")
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        entries.push((name.to_string(), profiles));
    }
    if entries.is_empty() {
        return Err("hooks/manifest.json contains no hook profile entries".to_string());
    }
    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_policy_dir(name: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "vibeguard_policy_{name}_{}_{}",
            std::process::id(),
            unique
        ));
        fs::create_dir_all(&root).expect("temp dir should be created");
        root
    }

    #[test]
    fn warn_mode_disabled_hook_policy_skips_canonical_name() {
        let repo = temp_policy_dir("disabled");
        fs::write(
            repo.join(".vibeguard.json"),
            r#"{"enforcement":"warn","disabled_hooks":["pre-bash-guard"]}"#,
        )
        .expect("project config should be written");

        let decision = evaluate_hook_policy(
            "vibeguard-pre-bash-guard.sh",
            repo.to_str(),
            &HashMap::new(),
        );

        assert!(
            matches!(decision, HookPolicyDecision::Skip(reason) if reason.contains("pre-bash-guard"))
        );
        let _ = fs::remove_dir_all(repo);
    }

    #[test]
    fn warn_enforcement_runs_in_warn_mode() {
        let repo = temp_policy_dir("warn");
        fs::write(repo.join(".vibeguard.json"), r#"{"enforcement":"warn"}"#)
            .expect("project config should be written");

        let decision = evaluate_hook_policy("pre-edit-guard.sh", repo.to_str(), &HashMap::new());

        assert!(matches!(
            decision,
            HookPolicyDecision::Run {
                warn_mode: true,
                ..
            }
        ));
        let _ = fs::remove_dir_all(repo);
    }

    #[test]
    fn minimal_profile_excludes_analysis_paralysis_guard() {
        let repo = temp_policy_dir("minimal_analysis");
        if let Err(err) = fs::write(repo.join(".vibeguard.json"), r#"{"profile":"minimal"}"#) {
            panic!("project config should be written: {err}");
        }

        let decision = evaluate_hook_policy(
            "analysis-paralysis-guard.sh",
            repo.to_str(),
            &HashMap::new(),
        );

        assert!(
            matches!(decision, HookPolicyDecision::Skip(reason) if reason.contains("profile=minimal excludes analysis-paralysis-guard"))
        );
        if let Err(err) = fs::remove_dir_all(&repo) {
            panic!("temp policy dir should be removed: {err}");
        }
    }

    #[test]
    fn core_profile_allows_analysis_paralysis_guard() {
        let repo = temp_policy_dir("core_analysis");
        if let Err(err) = fs::write(repo.join(".vibeguard.json"), r#"{"profile":"core"}"#) {
            panic!("project config should be written: {err}");
        }

        let decision = evaluate_hook_policy(
            "analysis-paralysis-guard.sh",
            repo.to_str(),
            &HashMap::new(),
        );

        assert!(matches!(
            decision,
            HookPolicyDecision::Run {
                warn_mode: false,
                ..
            }
        ));
        if let Err(err) = fs::remove_dir_all(&repo) {
            panic!("temp policy dir should be removed: {err}");
        }
    }

    #[test]
    fn omitted_profile_uses_core_default_for_full_only_hooks() {
        let repo = temp_policy_dir("default_core_profile");
        if let Err(err) = fs::write(repo.join(".vibeguard.json"), r#"{"enforcement":"block"}"#) {
            panic!("project config should be written: {err}");
        }

        let decision = evaluate_hook_policy("post-build-check.sh", repo.to_str(), &HashMap::new());

        assert!(
            matches!(decision, HookPolicyDecision::Skip(reason) if reason.contains("profile=core excludes post-build-check"))
        );
        if let Err(err) = fs::remove_dir_all(&repo) {
            panic!("temp policy dir should be removed: {err}");
        }
    }

    #[test]
    fn core_profile_runs_count_active_constraints() {
        let repo = temp_policy_dir("core_count_active_constraints");
        if let Err(err) = fs::write(repo.join(".vibeguard.json"), r#"{"profile":"core"}"#) {
            panic!("project config should be written: {err}");
        }

        let decision = evaluate_hook_policy(
            "count_active_constraints.sh",
            repo.to_str(),
            &HashMap::new(),
        );

        assert!(
            !matches!(decision, HookPolicyDecision::Skip(_)),
            "count_active_constraints should run under core profile, got: {decision:?}"
        );
        if let Err(err) = fs::remove_dir_all(&repo) {
            panic!("temp policy dir should be removed: {err}");
        }
    }

    #[test]
    fn runtime_profile_filter_matches_manifest_for_all_profiled_hooks() {
        let profiles = match manifest_profiles() {
            Ok(profiles) => profiles,
            Err(err) => panic!("manifest profiles should parse: {err}"),
        };
        assert_eq!(profiles, ["minimal", "core", "full", "strict"]);

        let hook_profiles = match manifest_hook_profiles() {
            Ok(hook_profiles) => hook_profiles,
            Err(err) => panic!("manifest hook profiles should parse: {err}"),
        };
        for (hook_name, allowed_profiles) in hook_profiles {
            for profile in &profiles {
                let repo = temp_policy_dir(&format!("{hook_name}_{profile}"));
                if let Err(err) = fs::write(
                    repo.join(".vibeguard.json"),
                    format!(r#"{{"profile":"{profile}"}}"#),
                ) {
                    panic!("project config should be written: {err}");
                }

                let decision = evaluate_hook_policy(
                    &format!("{hook_name}.sh"),
                    repo.to_str(),
                    &HashMap::new(),
                );
                let expected_allowed = allowed_profiles
                    .iter()
                    .any(|candidate| candidate == profile);

                if expected_allowed {
                    assert!(
                        matches!(
                            decision,
                            HookPolicyDecision::Run {
                                warn_mode: false,
                                ..
                            }
                        ),
                        "profile={profile} hook={hook_name} should run from hooks/manifest.json"
                    );
                } else {
                    assert!(
                        matches!(decision, HookPolicyDecision::Skip(reason) if reason.contains(&format!("profile={profile} excludes {hook_name}"))),
                        "profile={profile} hook={hook_name} should skip from hooks/manifest.json"
                    );
                }

                if let Err(err) = fs::remove_dir_all(&repo) {
                    panic!("temp policy dir should be removed: {err}");
                }
            }
        }
    }

    #[test]
    fn malformed_allowed_project_config_fields_return_policy_error() {
        let cases = [
            (
                "bad_languages_type",
                r#"{"languages":[123]}"#,
                "field languages must contain only strings",
            ),
            (
                "bad_disabled_rule",
                r#"{"disabled_rules":["not-a-rule"]}"#,
                ".disabled_rules.0: unsupported rule id not-a-rule",
            ),
            (
                "bad_disabled_guard",
                r#"{"disabled_guards":["missing_guard"]}"#,
                ".disabled_guards.0: unsupported value missing_guard",
            ),
            ("bad_gc_type", r#"{"gc":"bad"}"#, ".gc: expected object"),
            (
                "bad_gc_threshold",
                r#"{"gc":{"log_threshold_mb":0}}"#,
                ".gc.log_threshold_mb: expected integer >= 1",
            ),
            (
                "bad_gc_key",
                r#"{"gc":{"unexpected_gc_key":1}}"#,
                ".gc.unexpected_gc_key: unknown property",
            ),
        ];

        for (name, config, expected) in cases {
            let repo = temp_policy_dir(name);
            if let Err(err) = fs::write(repo.join(".vibeguard.json"), config) {
                panic!("project config should be written: {err}");
            }

            let decision =
                evaluate_hook_policy("pre-edit-guard.sh", repo.to_str(), &HashMap::new());

            assert!(
                matches!(decision, HookPolicyDecision::Error(reason) if reason.contains(expected)),
                "expected policy error containing {expected}"
            );
            if let Err(err) = fs::remove_dir_all(&repo) {
                panic!("temp policy dir should be removed: {err}");
            }
        }
    }

    #[test]
    fn invalid_json_returns_policy_error() {
        let repo = temp_policy_dir("invalid");
        fs::write(repo.join(".vibeguard.json"), "{").expect("project config should be written");

        let decision = evaluate_hook_policy("pre-edit-guard.sh", repo.to_str(), &HashMap::new());

        assert!(
            matches!(decision, HookPolicyDecision::Error(reason) if reason.contains("invalid JSON"))
        );
        let _ = fs::remove_dir_all(repo);
    }

    #[test]
    fn unsupported_disabled_hook_returns_policy_error() {
        let repo = temp_policy_dir("unsupported_disabled_hook");
        fs::write(
            repo.join(".vibeguard.json"),
            r#"{"disabled_hooks":["missing-hook"]}"#,
        )
        .expect("project config should be written");

        let decision = evaluate_hook_policy("pre-edit-guard.sh", repo.to_str(), &HashMap::new());

        assert!(
            matches!(decision, HookPolicyDecision::Error(reason) if reason.contains("unsupported hook missing-hook"))
        );
        let _ = fs::remove_dir_all(repo);
    }
}
