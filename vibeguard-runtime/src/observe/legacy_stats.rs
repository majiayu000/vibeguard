use serde_json::Value;
use std::collections::BTreeMap;

use crate::event_schema::{UNKNOWN, decision, field};

use super::Result;
use super::aggregate::{
    ObserveAggregate, observe_non_empty_or, observe_normalized_decision, observe_string_field,
};
use super::model::{ObserveOptions, TimeWindow};
use super::read::LogEvents;
use super::render::{
    legacy_count_by, legacy_decision_count, legacy_truncate, observe_blank_as_unknown,
    observe_increment, observe_sorted_counts,
};

pub(super) fn render_legacy_summary(
    options: &ObserveOptions,
    log_events: &LogEvents,
    aggregate: &ObserveAggregate,
) -> Result<String> {
    if aggregate.event_count == 0 {
        if !log_events.source_exists {
            return Ok(format!(
                "No log data. Hooks will be automatically logged to {} after being triggered\n",
                log_events.log_path
            ));
        }
        return Ok(match options.window {
            TimeWindow::All => "No log data.\n".to_string(),
            TimeWindow::Days(days) => format!("No log data for the last {days} days.\n"),
            TimeWindow::Hours(hours) => format!("No log data for the last {hours} hours.\n"),
        });
    }

    let hook_counts = legacy_count_by(&log_events.events, |event| {
        observe_non_empty_or(observe_string_field(event, field::HOOK), UNKNOWN)
    });
    let cli_counts = legacy_count_by(&log_events.events, |event| {
        observe_non_empty_or(observe_string_field(event, field::CLI), UNKNOWN)
    });
    let block_reasons = legacy_count_by_matching(&log_events.events, decision::BLOCK, |event| {
        observe_non_empty_or(observe_string_field(event, field::REASON), "Unknown")
    });
    let warn_reasons = legacy_count_by_matching(&log_events.events, decision::WARN, |event| {
        observe_non_empty_or(observe_string_field(event, field::REASON), "Unknown")
    });

    let mut output = String::new();
    output.push_str(&format!(
        "\nVibeGuard Statistics ({})\n{}\n",
        options.window.label(),
        "=".repeat(40)
    ));
    output.push_str(&format!(
        "Time range: {} ~ {}\n",
        observe_blank_as_unknown(&aggregate.first_ts),
        observe_blank_as_unknown(&aggregate.last_ts)
    ));
    output.push_str(&format!(
        "Total triggers: {} times\n",
        aggregate.event_count
    ));
    output.push_str(&format!(
        "  Interception (block): {} times\n",
        legacy_decision_count(aggregate, decision::BLOCK)
    ));
    output.push_str(&format!(
        "  Warning: {} times\n",
        legacy_decision_count(aggregate, decision::WARN)
    ));
    output.push_str(&format!(
        "  Pass (pass): {} times\n\n",
        legacy_decision_count(aggregate, decision::PASS)
    ));

    output.push_str("Distributed by Hook:\n");
    for (hook, count) in observe_sorted_counts(&hook_counts) {
        output.push_str(&format!(" {hook}: {count} times\n"));
    }

    output.push_str("\nDistributed by CLI:\n");
    for (cli, count) in observe_sorted_counts(&cli_counts) {
        output.push_str(&format!(" {cli}: {count} times\n"));
    }

    if !block_reasons.is_empty() {
        output.push_str("\nInterception reasons Top 5:\n");
        for (reason, count) in observe_sorted_counts(&block_reasons).into_iter().take(5) {
            output.push_str(&format!("  {count}x  {}\n", legacy_truncate(&reason, 60)));
        }
    }

    if !warn_reasons.is_empty() {
        output.push_str("\nWarning reasons Top 5:\n");
        for (reason, count) in observe_sorted_counts(&warn_reasons).into_iter().take(5) {
            output.push_str(&format!("  {count}x  {}\n", legacy_truncate(&reason, 60)));
        }
    }

    append_daily_counts(&mut output, &log_events.events);
    append_warn_compliance(&mut output, &log_events.events);
    append_file_type_distribution(&mut output, &log_events.events);
    append_time_distribution(&mut output, &log_events.events);
    append_performance_analysis(&mut output, &log_events.events);

    output.push('\n');
    Ok(output)
}

fn append_daily_counts(output: &mut String, events: &[Value]) {
    let day_counts = legacy_count_by_day(events);
    if day_counts.len() <= 1 {
        return;
    }
    output.push_str("\nDaily trigger amount:\n");
    for (day, count) in day_counts
        .iter()
        .rev()
        .take(7)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
    {
        let bar = std::iter::repeat_n('\u{2588}', (*count).min(50) as usize).collect::<String>();
        output.push_str(&format!("  {day}  {bar} {count}\n"));
    }
}

fn append_warn_compliance(output: &mut String, events: &[Value]) {
    if !events
        .iter()
        .any(|event| observe_normalized_decision(event) == decision::WARN)
    {
        return;
    }

    let mut by_hook: BTreeMap<String, (u64, u64)> = BTreeMap::new();
    for event in events {
        let decision_value = observe_normalized_decision(event);
        if !matches!(decision_value.as_str(), decision::WARN | decision::PASS) {
            continue;
        }
        let hook = observe_string_field(event, field::HOOK);
        let entry = by_hook.entry(hook).or_default();
        if decision_value == decision::WARN {
            entry.0 += 1;
        } else {
            entry.1 += 1;
        }
    }

    output.push_str("\n== Warn compliance rate analysis ==\n");
    let mut upgrade_candidates = Vec::new();
    for (hook, (warn_count, pass_count)) in &by_hook {
        if *warn_count == 0 {
            continue;
        }
        let total = warn_count + pass_count;
        let compliance = (*pass_count as f64 / total as f64) * 100.0;
        let indicator = if compliance >= 80.0 { "OK" } else { "LOW" };
        output.push_str(&format!(
            " {hook}: warn={warn_count} pass={pass_count} compliance rate={compliance:.0}% [{indicator}]\n"
        ));
        if compliance < 50.0 && *warn_count >= 3 {
            upgrade_candidates.push((hook.clone(), *warn_count, compliance));
        }
    }

    if !upgrade_candidates.is_empty() {
        output.push_str(
            "\nIt is recommended to upgrade to block (compliance rate < 50% and warn >= 3 times):\n",
        );
        for (hook, count, rate) in upgrade_candidates {
            output.push_str(&format!(
                " {hook}: {count} times warn, compliance rate {rate:.0}%\n"
            ));
        }
    }
}

fn append_file_type_distribution(output: &mut String, events: &[Value]) {
    let mut ext_counts = BTreeMap::new();
    for event in events {
        if let Some(ext) = legacy_file_extension(&observe_string_field(event, field::DETAIL)) {
            observe_increment(&mut ext_counts, ext);
        }
    }
    if ext_counts.is_empty() {
        return;
    }

    output.push_str("\nDistributed by file type:\n");
    for (ext, count) in observe_sorted_counts(&ext_counts).into_iter().take(10) {
        output.push_str(&format!(" .{ext}: {count} times\n"));
    }
}

fn append_time_distribution(output: &mut String, events: &[Value]) {
    let mut work_hours = 0_u64;
    let mut off_hours = 0_u64;
    for event in events {
        let ts = observe_string_field(event, field::TS);
        let Some(hour) = ts.get(11..13).and_then(|value| value.parse::<u64>().ok()) else {
            continue;
        };
        if (9..18).contains(&hour) {
            work_hours += 1;
        } else {
            off_hours += 1;
        }
    }
    let total = work_hours + off_hours;
    if total == 0 {
        return;
    }

    output.push_str("\nDistributed by time period:\n");
    output.push_str(&format!(
        " working time (09-18): {work_hours} times ({}%)\n",
        work_hours * 100 / total
    ));
    output.push_str(&format!(
        " Non-working hours: {off_hours} times ({}%)\n",
        off_hours * 100 / total
    ));
}

fn append_performance_analysis(output: &mut String, events: &[Value]) {
    let mut sessions: BTreeMap<String, Vec<&Value>> = BTreeMap::new();
    for event in events {
        let session = observe_string_field(event, field::SESSION);
        if !session.is_empty() {
            sessions.entry(session).or_default().push(event);
        }
    }
    if sessions.is_empty() {
        return;
    }

    output.push_str("\n== Performance analysis ==\n");
    output.push_str(&format!("Total number of sessions: {}\n", sessions.len()));
    let trigger_count = sessions.values().map(Vec::len).sum::<usize>();
    let avg_triggers = trigger_count as f64 / sessions.len() as f64;
    output.push_str(&format!(
        "Average triggers per session: {avg_triggers:.1} times\n"
    ));

    let mut block_rate_sum = 0.0_f64;
    let mut warn_rate_sum = 0.0_f64;
    for events in sessions.values() {
        let total = events.len() as f64;
        block_rate_sum += legacy_decision_ref_count(events, decision::BLOCK) as f64 / total * 100.0;
        warn_rate_sum += legacy_decision_ref_count(events, decision::WARN) as f64 / total * 100.0;
    }
    output.push_str(&format!(
        "Average block rate per session: {:.1}%\n",
        block_rate_sum / sessions.len() as f64
    ));
    output.push_str(&format!(
        "Average warning rate per session: {:.1}%\n",
        warn_rate_sum / sessions.len() as f64
    ));

    let deterministic_checks = events
        .iter()
        .filter(|event| {
            matches!(
                observe_normalized_decision(event).as_str(),
                decision::PASS | decision::BLOCK | decision::WARN
            )
        })
        .count() as u64;
    output.push_str(&format!(
        "Deterministic node estimated savings: ~{} tokens\n",
        legacy_token_savings_label(deterministic_checks * 500)
    ));

    append_problem_sessions(output, &sessions);
}

fn append_problem_sessions(output: &mut String, sessions: &BTreeMap<String, Vec<&Value>>) {
    let mut problem_sessions = sessions
        .iter()
        .map(|(session, events)| {
            (
                session,
                events,
                legacy_decision_ref_count(events, decision::BLOCK)
                    + legacy_decision_ref_count(events, decision::WARN),
            )
        })
        .collect::<Vec<_>>();
    problem_sessions.sort_by(|left, right| right.2.cmp(&left.2).then_with(|| left.0.cmp(right.0)));
    if !problem_sessions
        .iter()
        .take(3)
        .any(|(_, _, issues)| *issues > 0)
    {
        return;
    }

    output.push_str("\nConversations with the most questions Top 3:\n");
    for (session, events, issues) in problem_sessions.into_iter().take(3) {
        if issues == 0 {
            break;
        }
        let ts_start = events
            .first()
            .map(|event| legacy_ts_prefix(event))
            .unwrap_or_else(|| "?".to_string());
        let ts_end = events
            .last()
            .map(|event| legacy_ts_prefix(event))
            .unwrap_or_else(|| "?".to_string());
        output.push_str(&format!(
            " {session}: {issues} issues / {} triggers ({ts_start} ~ {ts_end})\n",
            events.len()
        ));
    }
}

fn legacy_count_by_matching<F>(
    events: &[Value],
    decision_value: &str,
    mut mapper: F,
) -> BTreeMap<String, u64>
where
    F: FnMut(&Value) -> String,
{
    let mut counts = BTreeMap::new();
    for event in events {
        if observe_normalized_decision(event) == decision_value {
            observe_increment(&mut counts, mapper(event));
        }
    }
    counts
}

fn legacy_count_by_day(events: &[Value]) -> BTreeMap<String, u64> {
    let mut counts = BTreeMap::new();
    for event in events {
        let ts = observe_string_field(event, field::TS);
        if ts.len() >= 10 {
            observe_increment(&mut counts, ts[..10].to_string());
        }
    }
    counts
}

fn legacy_decision_ref_count(events: &[&Value], decision_value: &str) -> u64 {
    events
        .iter()
        .filter(|event| observe_normalized_decision(event) == decision_value)
        .count() as u64
}

fn legacy_file_extension(detail: &str) -> Option<String> {
    for part in detail.split_whitespace() {
        let Some((_, ext)) = part.rsplit_once('.') else {
            continue;
        };
        let ext = ext.chars().take(5).collect::<String>();
        if !ext.is_empty() && ext.chars().all(|char| char.is_ascii_alphabetic()) {
            return Some(ext);
        }
    }
    None
}

fn legacy_token_savings_label(tokens: u64) -> String {
    if tokens >= 1_000_000 {
        format!("{:.1}M", tokens as f64 / 1_000_000.0)
    } else if tokens >= 1_000 {
        format!("{}K", tokens / 1_000)
    } else {
        tokens.to_string()
    }
}

fn legacy_ts_prefix(event: &Value) -> String {
    let ts = observe_string_field(event, field::TS);
    if ts.is_empty() {
        "?".to_string()
    } else {
        ts.chars().take(16).collect()
    }
}
