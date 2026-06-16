//! Canonical observability queries over VibeGuard JSONL event logs.

mod aggregate;
mod model;
mod prometheus;
mod read;
mod render;
mod stats_summary;

use crate::event_schema::field;
use crate::time_utils::now_unix_secs;

type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;

const OBSERVE_SCHEMA_VERSION: u64 = 1;
const DEFAULT_LIMIT: usize = 5_000;
const DEFAULT_SLOW_MS: u64 = 2_000;
const DEFAULT_TOP: usize = 10;

pub fn run(args: &[String]) -> Result {
    if args.first().is_some_and(|command| command == "export") {
        return prometheus::run(args);
    }

    let options = model::parse_observe_args(args)?;
    let mut log_events = read::read_log_events(&options)?;
    let cutoff_secs = options.window.cutoff_secs(now_unix_secs());
    log_events
        .events
        .retain(|event| read::event_passes_time_window(event, cutoff_secs));
    if let Some(session) = &options.session {
        log_events
            .events
            .retain(|event| aggregate::observe_string_field(event, field::SESSION) == *session);
    }
    log_events.events.sort_by(|left, right| {
        aggregate::observe_string_field(left, field::TS)
            .cmp(&aggregate::observe_string_field(right, field::TS))
            .then_with(|| {
                aggregate::observe_string_field(left, field::HOOK)
                    .cmp(&aggregate::observe_string_field(right, field::HOOK))
            })
    });

    let aggregate = aggregate::aggregate_events(&log_events.events, options.slow_ms);
    let output = match options.command {
        model::ObserveCommand::Summary => render::render_summary(&options, &log_events, &aggregate),
        model::ObserveCommand::Health => render::render_health(&options, &log_events, &aggregate),
        model::ObserveCommand::Session => render::render_session(&options, &log_events, &aggregate),
    }?;
    print!("{output}");
    Ok(())
}
