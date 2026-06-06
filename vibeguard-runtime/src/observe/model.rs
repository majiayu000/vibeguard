use std::path::PathBuf;

use crate::log_scope::{LogScope, parse_scope};

use super::{DEFAULT_LIMIT, DEFAULT_SLOW_MS, DEFAULT_TOP, Result};

#[derive(Clone, Copy, Debug)]
pub(super) enum ObserveCommand {
    Summary,
    Health,
    Session,
}

#[derive(Clone, Copy, Debug)]
pub(super) enum TimeWindow {
    All,
    Days(u64),
    Hours(u64),
}

impl TimeWindow {
    pub(super) fn cutoff_secs(self, now_secs: u64) -> Option<u64> {
        match self {
            Self::All => None,
            Self::Days(days) => Some(now_secs.saturating_sub(days.saturating_mul(86_400))),
            Self::Hours(hours) => Some(now_secs.saturating_sub(hours.saturating_mul(3_600))),
        }
    }

    pub(super) fn label(self) -> String {
        match self {
            Self::All => "all history".to_string(),
            Self::Days(days) => format!("last {days} days"),
            Self::Hours(hours) => format!("last {hours} hours"),
        }
    }
}

#[derive(Debug)]
pub(super) struct ObserveOptions {
    pub(super) command: ObserveCommand,
    pub(super) json: bool,
    pub(super) legacy: bool,
    pub(super) log_file: Option<PathBuf>,
    pub(super) scope: LogScope,
    pub(super) scope_explicit: bool,
    pub(super) project: Option<String>,
    pub(super) limit: usize,
    pub(super) slow_ms: u64,
    pub(super) top: usize,
    pub(super) window: TimeWindow,
    pub(super) session: Option<String>,
}

impl ObserveOptions {
    fn new(command: ObserveCommand) -> Self {
        let window = match command {
            ObserveCommand::Summary => TimeWindow::Days(7),
            ObserveCommand::Health => TimeWindow::Hours(24),
            ObserveCommand::Session => TimeWindow::All,
        };
        Self {
            command,
            json: false,
            legacy: false,
            log_file: None,
            scope: LogScope::Project,
            scope_explicit: false,
            project: None,
            limit: DEFAULT_LIMIT,
            slow_ms: DEFAULT_SLOW_MS,
            top: DEFAULT_TOP,
            window,
            session: None,
        }
    }
}

pub(super) fn parse_observe_args(args: &[String]) -> Result<ObserveOptions> {
    let Some(command_name) = args.first() else {
        return Err(usage().into());
    };
    match command_name.as_str() {
        "summary" => parse_command(ObserveCommand::Summary, None, &args[1..]),
        "health" => parse_command(ObserveCommand::Health, None, &args[1..]),
        "session" => {
            let session = args
                .get(1)
                .filter(|value| !value.starts_with('-'))
                .ok_or("Usage: vibeguard-runtime observe session <session-id> [options]")?;
            parse_command(
                ObserveCommand::Session,
                Some(session.to_string()),
                &args[2..],
            )
        }
        "--help" | "-h" => Err(usage().into()),
        other => Err(format!("unknown observe command: {other}").into()),
    }
}

fn parse_command(
    command: ObserveCommand,
    session: Option<String>,
    args: &[String],
) -> Result<ObserveOptions> {
    let mut options = ObserveOptions::new(command);
    options.session = session;
    parse_common_args(args, &mut options)?;
    Ok(options)
}

fn parse_common_args(args: &[String], options: &mut ObserveOptions) -> Result {
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--json" => options.json = true,
            "--legacy" => options.legacy = true,
            "--log-file" => {
                index += 1;
                options.log_file = Some(PathBuf::from(value_arg(args, index, "--log-file")?));
            }
            "--scope" => {
                index += 1;
                options.scope = parse_scope(value_arg(args, index, "--scope")?)?;
                options.scope_explicit = true;
            }
            "--project" => {
                index += 1;
                options.project = Some(value_arg(args, index, "--project")?.to_string());
                options.scope = LogScope::Project;
                options.scope_explicit = true;
            }
            "--limit" => {
                index += 1;
                options.limit = parse_limit(value_arg(args, index, "--limit")?)?;
            }
            "--slow-ms" => {
                index += 1;
                options.slow_ms = value_arg(args, index, "--slow-ms")?.parse::<u64>()?;
            }
            "--top" => {
                index += 1;
                options.top = parse_positive_usize(value_arg(args, index, "--top")?, "--top")?;
            }
            "--days" => {
                index += 1;
                options.window = parse_days_window(value_arg(args, index, "--days")?)?;
            }
            "--hours" => {
                index += 1;
                options.window = parse_hours_window(value_arg(args, index, "--hours")?)?;
            }
            "--help" | "-h" => return Err(usage().into()),
            other => return Err(format!("unknown observe argument: {other}").into()),
        }
        index += 1;
    }
    Ok(())
}

fn value_arg<'a>(args: &'a [String], index: usize, name: &str) -> Result<&'a str> {
    args.get(index)
        .map(String::as_str)
        .ok_or_else(|| format!("{name} requires a value").into())
}

fn parse_limit(value: &str) -> Result<usize> {
    if value == "all" {
        return Ok(usize::MAX);
    }
    parse_positive_usize(value, "--limit")
}

fn parse_positive_usize(value: &str, name: &str) -> Result<usize> {
    let parsed = value.parse::<usize>()?;
    if parsed == 0 {
        return Err(format!("{name} must be greater than 0").into());
    }
    Ok(parsed)
}

fn parse_days_window(value: &str) -> Result<TimeWindow> {
    if value == "all" {
        return Ok(TimeWindow::All);
    }
    let days = value.parse::<u64>()?;
    if days == 0 {
        return Err("--days must be greater than 0 or all".into());
    }
    Ok(TimeWindow::Days(days))
}

fn parse_hours_window(value: &str) -> Result<TimeWindow> {
    if value == "all" {
        return Ok(TimeWindow::All);
    }
    let hours = value.parse::<u64>()?;
    if hours == 0 {
        return Err("--hours must be greater than 0 or all".into());
    }
    Ok(TimeWindow::Hours(hours))
}

fn usage() -> &'static str {
    "Usage: vibeguard-runtime observe <summary|health|session|export prometheus> [--json] [--legacy] [--scope project|global] [--project PATH_OR_HASH] [--log-file PATH] [--days N|all] [--hours N|all] [--limit N|all] [--slow-ms MS] [--top N]"
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_string()).collect()
    }

    #[test]
    fn summary_defaults_to_json_false_and_seven_days() {
        let options = match parse_observe_args(&args(&["summary"])) {
            Ok(options) => options,
            Err(error) => panic!("summary options should parse: {error}"),
        };

        assert!(matches!(options.command, ObserveCommand::Summary));
        assert!(!options.json);
        assert_eq!(options.window.label(), "last 7 days");
    }

    #[test]
    fn session_accepts_id_and_common_options() {
        let options = match parse_observe_args(&args(&[
            "session", "s1", "--json", "--hours", "all", "--limit", "42", "--top", "3",
        ])) {
            Ok(options) => options,
            Err(error) => panic!("session options should parse: {error}"),
        };

        assert!(matches!(options.command, ObserveCommand::Session));
        assert_eq!(options.session.as_deref(), Some("s1"));
        assert!(options.json);
        assert_eq!(options.window.label(), "all history");
        assert_eq!(options.limit, 42);
        assert_eq!(options.top, 3);
    }

    #[test]
    fn zero_limit_is_rejected() {
        let error = match parse_observe_args(&args(&["health", "--limit", "0"])) {
            Ok(_) => panic!("zero limit should fail"),
            Err(error) => error,
        };

        assert!(error.to_string().contains("--limit must be greater than 0"));
    }

    #[test]
    fn all_limit_uses_maximum_read_window() {
        let options = match parse_observe_args(&args(&["summary", "--limit", "all"])) {
            Ok(options) => options,
            Err(error) => panic!("all limit should parse: {error}"),
        };

        assert_eq!(options.limit, usize::MAX);
    }
}
