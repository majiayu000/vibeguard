use crate::project_config::{load_project_config, project_config_path};
use std::collections::HashMap;
use std::path::Path;

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
    if !profile_allows_hook(profile, &canonical_hook) {
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

fn profile_allows_hook(profile: &str, hook_name: &str) -> bool {
    match hook_name {
        "analysis-paralysis-guard" => matches!(profile, "core" | "full" | "strict"),
        "count-active-constraints" => profile == "strict",
        "post-build-check" | "stop-guard" | "learn-evaluator" => {
            matches!(profile, "full" | "strict")
        }
        _ => true,
    }
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
    fn core_profile_excludes_strict_only_count_active_constraints() {
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
            matches!(decision, HookPolicyDecision::Skip(reason) if reason.contains("profile=core excludes count-active-constraints"))
        );
        if let Err(err) = fs::remove_dir_all(&repo) {
            panic!("temp policy dir should be removed: {err}");
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
