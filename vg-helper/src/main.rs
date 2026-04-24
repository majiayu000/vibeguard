mod json_field;
mod log_query;
mod pkg_rewrite;
mod session_metrics;

use std::env;
use std::process;

type HandlerResult = std::result::Result<(), Box<dyn std::error::Error>>;

struct Command {
    name: &'static str,
    usage: &'static str,
    handler: fn(&[String]) -> HandlerResult,
}

static COMMANDS: &[Command] = &[
    Command {
        name: "json-field",
        usage: "<field_path>  — extract one field from stdin JSON",
        handler: json_field::run_field,
    },
    Command {
        name: "json-two-fields",
        usage: "<field1> <field2>  — extract two fields from stdin JSON",
        handler: json_field::run_two_fields,
    },
    Command {
        name: "churn-count",
        usage: "<session> <file>  — count Edit events for a file",
        handler: log_query::churn_count,
    },
    Command {
        name: "warn-count",
        usage: "<session> <file>  — count warn events for a file",
        handler: log_query::warn_count,
    },
    Command {
        name: "build-fails",
        usage: "<session> <project>  — count consecutive build failures",
        handler: log_query::build_fails,
    },
    Command {
        name: "paralysis-count",
        usage: "<session>  — count consecutive read-only tool calls",
        handler: log_query::paralysis_count,
    },
    Command {
        name: "pkg-rewrite",
        usage: "  — rewrite package manager command from stdin",
        handler: pkg_rewrite::run,
    },
    Command {
        name: "session-metrics",
        usage: "<session> <dir>  — emit session metrics and correction signals",
        handler: session_metrics::run,
    },
];

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: vg-helper <command> [args...]");
        for cmd in COMMANDS {
            eprintln!("  {}  {}", cmd.name, cmd.usage);
        }
        process::exit(2);
    }

    match COMMANDS.iter().find(|c| c.name == args[1].as_str()) {
        None => {
            eprintln!("Unknown command: {}", args[1]);
            process::exit(2);
        }
        Some(cmd) => {
            if let Err(e) = (cmd.handler)(&args[2..]) {
                eprintln!("vg-helper error: {e}");
                process::exit(1);
            }
        }
    }
}
