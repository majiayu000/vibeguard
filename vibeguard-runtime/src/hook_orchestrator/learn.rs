use serde_json::{Value, json};
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::time::Instant;

use crate::event_schema::{decision, status};
use crate::git_root::current_git_root_by_marker;
use crate::hook_orchestrator::context::RuntimeContext;
use crate::hook_orchestrator::{HookKind, Result, append_hook_event, elapsed_ms};
use crate::runtime_config::runtime_config_int_value;
use crate::session_metrics;
use crate::wrapper_env::env_nonempty;

pub(crate) fn run(input: &str, start: Instant) -> Result {
    if learn_is_ci() || learn_stop_hook_active(input)? || current_git_root_by_marker().is_none() {
        return Ok(());
    }

    let ctx = RuntimeContext::collect()
        .map_err(|err| format!("failed to collect context for learn-evaluator event: {err}"))?;

    let tail_bytes = runtime_config_int_value(
        "VIBEGUARD_LEARN_METRICS_TAIL_BYTES",
        "learn.metrics_tail_bytes",
        "5242880",
    ) as usize;
    log_truncation_once(&ctx, tail_bytes, start)?;
    let events = match recent_log_text(&ctx.log_file, tail_bytes) {
        Ok(events) => events,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(err) => {
            return Err(format!(
                "failed to read learn-evaluator events from {}: {err}",
                ctx.log_file.display()
            )
            .into());
        }
    };
    let metrics_output = session_metrics::run_text(
        &ctx.session_id,
        &ctx.log_file
            .parent()
            .unwrap_or(Path::new(""))
            .to_string_lossy(),
        &events,
    )
    .map_err(|err| format!("failed to calculate or persist session metrics: {err}"))?;
    let mut lines = metrics_output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty());
    if lines.next() != Some("LEARN_SUGGESTED") {
        return Ok(());
    }
    let signals = lines.map(str::to_string).collect::<Vec<_>>();
    if signals.is_empty() {
        return Ok(());
    }
    let signal_list = signals.join("; ");
    let reason = format!(
        "[VibeGuard correction detection] {} signals: {}. It is recommended to run /vibeguard:learn",
        signals.len(),
        signal_list
    );
    println!(
        "{}",
        serde_json::to_string(&json!({
            "stopReason": reason,
        }))?
    );
    Ok(())
}

fn learn_is_ci() -> bool {
    fn learn_truthy_env(name: &str) -> bool {
        matches!(
            env::var(name).as_deref(),
            Ok("true" | "True" | "TRUE" | "1" | "yes" | "Yes" | "YES")
        )
    }
    learn_truthy_env("CI")
        || learn_truthy_env("GITHUB_ACTIONS")
        || learn_truthy_env("TRAVIS")
        || learn_truthy_env("CIRCLECI")
        || env_nonempty("JENKINS_URL").is_some()
        || learn_truthy_env("GITLAB_CI")
        || learn_truthy_env("TF_BUILD")
}

fn learn_stop_hook_active(input: &str) -> Result<bool> {
    let data = serde_json::from_str::<Value>(input)
        .map_err(|err| format!("invalid learn-evaluator Stop input: {err}"))?;
    Ok(data
        .get("stop_hook_active")
        .and_then(Value::as_bool)
        .unwrap_or(false))
}

fn log_truncation_once(ctx: &RuntimeContext, tail_bytes: usize, start: Instant) -> Result {
    if tail_bytes == 0 {
        return Ok(());
    }
    let metadata = match fs::metadata(&ctx.log_file) {
        Ok(metadata) => metadata,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(err) => {
            return Err(format!(
                "failed to inspect learn-evaluator log {}: {err}",
                ctx.log_file.display()
            )
            .into());
        }
    };
    if metadata.len() <= tail_bytes as u64 {
        return Ok(());
    }
    let session_key = sanitize_session_key(&ctx.session_id);
    let flag_file = ctx
        .log_root
        .join(format!(".learn_metrics_truncated_{session_key}"));
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&flag_file)
    {
        Ok(file) => drop(file),
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => return Ok(()),
        Err(err) => {
            return Err(format!(
                "failed to create learn-evaluator truncation marker {}: {err}",
                flag_file.display()
            )
            .into());
        }
    }
    let reason = format!(
        "metrics input truncated to {tail_bytes} bytes before 30-minute filter; increase VIBEGUARD_LEARN_METRICS_TAIL_BYTES for very busy sessions"
    );
    if let Err(append_err) = append_hook_event(
        ctx,
        HookKind::Learn,
        decision::WARN,
        status::WARN,
        &reason,
        &ctx.log_file.to_string_lossy(),
        elapsed_ms(start),
    ) {
        match fs::remove_file(&flag_file) {
            Ok(()) => return Err(append_err),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Err(append_err),
            Err(err) => {
                return Err(format!(
                    "{append_err}; additionally failed to remove learn-evaluator truncation marker {}: {err}",
                    flag_file.display()
                )
                .into());
            }
        }
    }
    Ok(())
}

fn sanitize_session_key(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.' | '-') {
                ch
            } else {
                '_'
            }
        })
        .collect()
}

fn recent_log_text(path: &Path, tail_bytes: usize) -> std::io::Result<String> {
    let mut file = File::open(path)?;
    if tail_bytes > 0 {
        let len = file.metadata()?.len();
        if len > tail_bytes as u64 {
            file.seek(SeekFrom::Start(len - tail_bytes as u64))?;
        }
    }
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::error::Error;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn test_context(root: PathBuf) -> RuntimeContext {
        RuntimeContext {
            log_root: root.clone(),
            log_file: root.join("projects").join("test").join("events.jsonl"),
            project_hash: "test".to_string(),
            session_id: "retry-session".to_string(),
            cli: "codex".to_string(),
            client: "codex".to_string(),
            client_variant: "codex-cli-hooks".to_string(),
            caller_evidence: "test".to_string(),
            session_source: "codex-thread".to_string(),
        }
    }

    #[test]
    fn stop_hook_active_is_read_from_hook_input() {
        assert!(learn_stop_hook_active(r#"{"stop_hook_active":true}"#).unwrap());
        assert!(!learn_stop_hook_active(r#"{"stop_hook_active":false}"#).unwrap());
        assert!(learn_stop_hook_active("{").is_err());
    }

    #[test]
    fn session_key_sanitizer_preserves_safe_chars_only() {
        assert_eq!(sanitize_session_key("abc_123.-"), "abc_123.-");
        assert_eq!(sanitize_session_key("a/b c:1"), "a_b_c_1");
    }

    #[test]
    fn recent_log_text_reads_only_requested_tail_bytes() -> std::result::Result<(), Box<dyn Error>>
    {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let path = env::temp_dir().join(format!("vibeguard-learn-tail-{unique}.jsonl"));
        fs::write(&path, "0123456789")?;

        assert_eq!(recent_log_text(&path, 4)?, "6789");
        assert_eq!(recent_log_text(&path, 0)?, "0123456789");

        fs::remove_file(path).ok();
        Ok(())
    }

    #[test]
    fn recent_log_text_reports_non_file_inputs() -> std::result::Result<(), Box<dyn Error>> {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let path = env::temp_dir().join(format!("vibeguard-learn-dir-{unique}"));
        fs::create_dir(&path)?;

        assert!(recent_log_text(&path, 0).is_err());

        fs::remove_dir(path)?;
        Ok(())
    }

    #[test]
    fn truncation_marker_is_removed_when_warning_persistence_fails()
    -> std::result::Result<(), Box<dyn Error>> {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let root = env::temp_dir().join(format!("vibeguard-learn-retry-{unique}"));
        let ctx = test_context(root.clone());
        fs::create_dir_all(ctx.log_file.parent().unwrap_or(&root))?;
        fs::write(&ctx.log_file, "0123456789")?;

        let global_log = root.join("events.jsonl");
        fs::create_dir_all(&global_log)?;
        let marker = root.join(".learn_metrics_truncated_retry-session");

        assert!(log_truncation_once(&ctx, 1, Instant::now()).is_err());
        assert!(!marker.exists());

        fs::remove_dir(&global_log)?;
        log_truncation_once(&ctx, 1, Instant::now())?;
        assert!(marker.is_file());
        assert!(fs::read_to_string(&global_log)?.contains("metrics input truncated"));

        fs::remove_dir_all(root)?;
        Ok(())
    }
}
