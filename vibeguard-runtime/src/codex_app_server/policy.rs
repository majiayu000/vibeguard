use crate::installed_profile::installed_profile;
use crate::project_config::{load_project_config, project_config_path};
use crate::setup::support::home_dir;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::Path;
use std::sync::OnceLock;

const HOOKS_MANIFEST_JSON: &str = include_str!("../../../hooks/manifest.json");
const DEFAULT_PROFILE: &str = "core";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AppServerHookCatalog {
    pub command_pre: String,
    pub file_pre_edit: String,
    pub file_pre_write: String,
    pub file_post_edit: String,
    pub file_post_write: String,
    pub analysis_observer: String,
    pub post_turn_build: String,
    pub post_turn: Vec<String>,
    required: BTreeSet<String>,
}

pub(crate) fn app_server_hook_catalog() -> Result<AppServerHookCatalog, String> {
    static CATALOG: OnceLock<Result<AppServerHookCatalog, String>> = OnceLock::new();
    CATALOG
        .get_or_init(|| parse_app_server_hook_catalog(HOOKS_MANIFEST_JSON))
        .clone()
}

fn parse_app_server_hook_catalog(json: &str) -> Result<AppServerHookCatalog, String> {
    let manifest = serde_json::from_str::<Value>(json)
        .map_err(|err| format!("hooks/manifest.json invalid JSON: {err}"))?;
    let hooks = manifest
        .get("hooks")
        .and_then(Value::as_array)
        .ok_or_else(|| "hooks/manifest.json missing hooks array".to_string())?;
    let mut roles = BTreeMap::<(String, Option<String>), Vec<String>>::new();
    let mut required = BTreeSet::new();

    for hook in hooks {
        let Some(app_server) = hook.get("app_server") else {
            continue;
        };
        let app_server = app_server
            .as_object()
            .ok_or_else(|| "hooks/manifest.json app_server entry must be an object".to_string())?;
        let name = hook
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| "hooks/manifest.json hook entry missing string name".to_string())?;
        let script = hook
            .get("script")
            .and_then(Value::as_str)
            .ok_or_else(|| format!("hooks/manifest.json hook {name} missing string script"))?;
        if Path::new(script)
            .file_name()
            .and_then(|value| value.to_str())
            != Some(script)
            || !script.ends_with(".sh")
        {
            return Err(format!(
                "hooks/manifest.json hook {name} app_server script must be a .sh basename"
            ));
        }
        let role = app_server
            .get("role")
            .and_then(Value::as_str)
            .ok_or_else(|| format!("hooks/manifest.json hook {name} missing app_server.role"))?;
        if !matches!(
            role,
            "command_pre"
                | "file_pre"
                | "file_post"
                | "analysis_observer"
                | "post_turn_build"
                | "post_turn"
        ) {
            return Err(format!(
                "hooks/manifest.json hook {name} has unsupported app_server.role {role}"
            ));
        }
        let tool = app_server
            .get("tool")
            .map(|value| {
                value.as_str().map(str::to_string).ok_or_else(|| {
                    format!("hooks/manifest.json hook {name} app_server.tool must be a string")
                })
            })
            .transpose()?;
        if matches!(role, "file_pre" | "file_post") != tool.is_some() {
            return Err(format!(
                "hooks/manifest.json hook {name} app_server.tool must be set only for file roles"
            ));
        }
        roles
            .entry((role.to_string(), tool))
            .or_default()
            .push(script.to_string());
        if app_server.get("required").and_then(Value::as_bool) == Some(true) {
            required.insert(script.to_string());
        }
    }

    let catalog = AppServerHookCatalog {
        command_pre: take_single_role(&mut roles, "command_pre", None)?,
        file_pre_edit: take_single_role(&mut roles, "file_pre", Some("Edit"))?,
        file_pre_write: take_single_role(&mut roles, "file_pre", Some("Write"))?,
        file_post_edit: take_single_role(&mut roles, "file_post", Some("Edit"))?,
        file_post_write: take_single_role(&mut roles, "file_post", Some("Write"))?,
        analysis_observer: take_single_role(&mut roles, "analysis_observer", None)?,
        post_turn_build: take_single_role(&mut roles, "post_turn_build", None)?,
        post_turn: take_many_role(&mut roles, "post_turn")?,
        required,
    };
    if !roles.is_empty() {
        return Err(format!(
            "hooks/manifest.json contains unused app_server role/tool mappings: {:?}",
            roles.keys().collect::<Vec<_>>()
        ));
    }
    Ok(catalog)
}

fn take_single_role(
    roles: &mut BTreeMap<(String, Option<String>), Vec<String>>,
    role: &str,
    tool: Option<&str>,
) -> Result<String, String> {
    let key = (role.to_string(), tool.map(str::to_string));
    let entries = roles.remove(&key).unwrap_or_default();
    if entries.len() != 1 {
        return Err(format!(
            "hooks/manifest.json app_server role {role} tool={} must resolve to exactly one hook, found {}",
            tool.unwrap_or("<none>"),
            entries.len()
        ));
    }
    entries
        .into_iter()
        .next()
        .ok_or_else(|| format!("hooks/manifest.json app_server role {role} disappeared"))
}

fn take_many_role(
    roles: &mut BTreeMap<(String, Option<String>), Vec<String>>,
    role: &str,
) -> Result<Vec<String>, String> {
    let entries = roles.remove(&(role.to_string(), None)).unwrap_or_default();
    if entries.is_empty() {
        return Err(format!(
            "hooks/manifest.json app_server role {role} must resolve to at least one hook"
        ));
    }
    Ok(entries)
}

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
    let canonical_hook = app_server_canonical_hook_name(hook_name);
    let Some(path) = project_config_path(cwd, env_overrides) else {
        let default_profile = match default_runtime_profile(env_overrides) {
            Ok(profile) => profile,
            Err(reason) => return HookPolicyDecision::Error(reason),
        };
        let profile_allowed = match manifest_profile_allows_hook(&default_profile, &canonical_hook)
        {
            Ok(allowed) => allowed,
            Err(reason) => return HookPolicyDecision::Error(reason),
        };
        if !profile_allowed {
            return HookPolicyDecision::Skip(format!(
                "VibeGuard policy skip: profile={default_profile} excludes {canonical_hook}"
            ));
        }
        return HookPolicyDecision::Run {
            warn_mode: false,
            reason: None,
        };
    };

    let config = match load_project_config(&path) {
        Ok(config) => config,
        Err(reason) => return HookPolicyDecision::Error(reason),
    };

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

    let profile = match config.profile {
        Some(profile) => profile,
        None => match default_runtime_profile(env_overrides) {
            Ok(profile) => profile,
            Err(reason) => return HookPolicyDecision::Error(reason),
        },
    };
    let profile_allowed = match manifest_profile_allows_hook(&profile, &canonical_hook) {
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

pub(crate) fn default_runtime_profile(
    env_overrides: &HashMap<String, String>,
) -> Result<String, String> {
    default_runtime_profile_from_home(env_overrides, home_dir().as_deref())
}

fn default_runtime_profile_from_home(
    env_overrides: &HashMap<String, String>,
    home: Option<&Path>,
) -> Result<String, String> {
    let explicit_profile = env_overrides
        .get("VIBEGUARD_PROFILE")
        .cloned()
        .or_else(|| std::env::var("VIBEGUARD_PROFILE").ok())
        .filter(|value| !value.is_empty());
    runtime_profile_from_sources(explicit_profile, home)
}

fn runtime_profile_from_sources(
    explicit_profile: Option<String>,
    home: Option<&Path>,
) -> Result<String, String> {
    let profile = match explicit_profile {
        Some(profile) => profile,
        None => match home {
            Some(home) => installed_profile(home)?.unwrap_or_else(|| DEFAULT_PROFILE.to_string()),
            None => DEFAULT_PROFILE.to_string(),
        },
    };
    let profiles = manifest_profiles()?;
    if profiles.iter().any(|value| value == &profile) {
        Ok(profile)
    } else {
        Err(format!(
            "VibeGuard policy error: unsupported VIBEGUARD_PROFILE={profile} (expected {})",
            profiles.join("|")
        ))
    }
}

pub fn required_hook_missing_message(
    hook_name: &str,
    hook_path: &Path,
) -> Result<Option<String>, String> {
    if app_server_hook_catalog()?.required.contains(hook_name) {
        return Ok(Some(format!(
            "VIBEGUARD install incomplete: missing required hook {hook_name} at {}",
            hook_path.display()
        )));
    }
    Ok(None)
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
    fn app_server_catalog_resolves_every_strategy_role_from_manifest() {
        let catalog = parse_app_server_hook_catalog(HOOKS_MANIFEST_JSON)
            .unwrap_or_else(|err| panic!("app-server catalog should parse: {err}"));

        assert_eq!(catalog.command_pre, "pre-bash-guard.sh");
        assert_eq!(catalog.file_pre_edit, "pre-edit-guard.sh");
        assert_eq!(catalog.file_pre_write, "pre-write-guard.sh");
        assert_eq!(catalog.file_post_edit, "post-edit-guard.sh");
        assert_eq!(catalog.file_post_write, "post-write-guard.sh");
        assert_eq!(catalog.analysis_observer, "analysis-paralysis-guard.sh");
        assert_eq!(catalog.post_turn_build, "post-build-check.sh");
        assert_eq!(catalog.post_turn, ["stop-guard.sh", "learn-evaluator.sh"]);
        assert_eq!(
            catalog.required,
            [
                "pre-bash-guard.sh".to_string(),
                "pre-edit-guard.sh".to_string(),
                "pre-write-guard.sh".to_string(),
            ]
            .into_iter()
            .collect()
        );
    }

    #[test]
    fn app_server_catalog_rejects_unknown_roles() {
        let error = parse_app_server_hook_catalog(
            r#"{"hooks":[{"name":"bad","script":"bad.sh","app_server":{"role":"unknown"}}]}"#,
        )
        .expect_err("unknown app-server role should fail");

        assert!(error.contains("unsupported app_server.role unknown"));
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

        let env = HashMap::from([("VIBEGUARD_PROFILE".to_string(), "core".to_string())]);
        let decision = evaluate_hook_policy("post-build-check.sh", repo.to_str(), &env);

        assert!(
            matches!(decision, HookPolicyDecision::Skip(reason) if reason.contains("profile=core excludes post-build-check"))
        );
        if let Err(err) = fs::remove_dir_all(&repo) {
            panic!("temp policy dir should be removed: {err}");
        }
    }

    #[test]
    fn installed_profile_is_the_default_after_explicit_environment() {
        let home = temp_policy_dir("installed_profile_default");
        let state_dir = home.join(".vibeguard");
        fs::create_dir_all(&state_dir).expect("state directory should be created");
        fs::write(
            state_dir.join("install-state.json"),
            r#"{"version":1,"generation":1,"complete":true,"profile":"full","files":{}}"#,
        )
        .expect("install-state should be written");

        assert_eq!(
            runtime_profile_from_sources(None, Some(&home)),
            Ok("full".to_string())
        );
        assert_eq!(
            runtime_profile_from_sources(Some("minimal".to_string()), Some(&home)),
            Ok("minimal".to_string())
        );
        fs::remove_dir_all(home).expect("temp home should be removed");
    }

    #[test]
    fn project_profile_overrides_explicit_environment() {
        let repo = temp_policy_dir("project_profile_precedence");
        fs::write(repo.join(".vibeguard.json"), r#"{"profile":"core"}"#)
            .expect("project config should be written");
        let env = HashMap::from([("VIBEGUARD_PROFILE".to_string(), "full".to_string())]);

        let decision = evaluate_hook_policy("post-build-check.sh", repo.to_str(), &env);

        assert!(
            matches!(decision, HookPolicyDecision::Skip(reason) if reason.contains("profile=core excludes post-build-check"))
        );
        fs::remove_dir_all(repo).expect("temp repo should be removed");
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
