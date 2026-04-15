mod json_field;
mod log_query;
mod pkg_rewrite;
mod session_metrics;

use std::env;
use std::process;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: vg-helper <command> [args...]");
        eprintln!("Commands: json-field, json-two-fields, churn-count, warn-count,");
        eprintln!("          build-fails, paralysis-count, pkg-rewrite, session-metrics");
        process::exit(1);
    }

    let result = match args[1].as_str() {
        "json-field" => json_field::run_field(&args[2..]),
        "json-two-fields" => json_field::run_two_fields(&args[2..]),
        "churn-count" => log_query::churn_count(&args[2..]),
        "warn-count" => log_query::warn_count(&args[2..]),
        "build-fails" => log_query::build_fails(&args[2..]),
        "paralysis-count" => log_query::paralysis_count(&args[2..]),
        "pkg-rewrite" => pkg_rewrite::run(&args[2..]),
        "session-metrics" => session_metrics::run(&args[2..]),
        cmd => {
            eprintln!("Unknown command: {cmd}");
            process::exit(1);
        }
    };

    if let Err(e) = result {
        eprintln!("vg-helper error: {e}");
        process::exit(1);
    }
}
