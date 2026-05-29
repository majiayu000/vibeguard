use crate::codex_app_server_core::{GateStrategy, NoopGateStrategy, SessionState};
use crate::codex_app_server_strategies::VibeGuardGateStrategy;
use serde_json::Value;
use std::error::Error;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::Duration;

#[derive(Debug)]
struct Args {
    repo_dir: PathBuf,
    strategy: String,
    codex_command: String,
}

pub fn run(args: &[String]) -> Result<(), Box<dyn Error>> {
    let args = parse_args(args)?;
    let strategy: Box<dyn GateStrategy> = match args.strategy.as_str() {
        "noop" => Box::new(NoopGateStrategy),
        "vibeguard" => Box::new(VibeGuardGateStrategy::new(&args.repo_dir, None)?),
        other => return Err(format!("unsupported strategy: {other}").into()),
    };

    run_proxy(strategy, &args.codex_command)
}

fn parse_args(args: &[String]) -> Result<Args, Box<dyn Error>> {
    let mut repo_dir: Option<PathBuf> = None;
    let mut strategy = "vibeguard".to_string();
    let mut codex_command = "codex app-server".to_string();
    let mut idx = 0;
    while idx < args.len() {
        match args[idx].as_str() {
            "-h" | "--help" => {
                print_help();
                std::process::exit(0);
            }
            "--repo-dir" => {
                idx += 1;
                repo_dir = Some(PathBuf::from(
                    args.get(idx).ok_or("--repo-dir requires a value")?,
                ));
            }
            "--strategy" => {
                idx += 1;
                strategy = args.get(idx).ok_or("--strategy requires a value")?.clone();
            }
            "--codex-command" => {
                idx += 1;
                codex_command = args
                    .get(idx)
                    .ok_or("--codex-command requires a value")?
                    .clone();
            }
            arg if arg.starts_with("--repo-dir=") => {
                repo_dir = Some(PathBuf::from(arg.trim_start_matches("--repo-dir=")));
            }
            arg if arg.starts_with("--strategy=") => {
                strategy = arg.trim_start_matches("--strategy=").to_string();
            }
            arg if arg.starts_with("--codex-command=") => {
                codex_command = arg.trim_start_matches("--codex-command=").to_string();
            }
            arg => return Err(format!("unknown argument: {arg}").into()),
        }
        idx += 1;
    }

    Ok(Args {
        repo_dir: repo_dir.unwrap_or_else(default_repo_dir),
        strategy,
        codex_command,
    })
}

fn print_help() {
    println!(
        "Usage: vibeguard-runtime codex-app-server-wrapper [--repo-dir DIR] [--strategy vibeguard|noop] [--codex-command CMD]"
    );
}

fn default_repo_dir() -> PathBuf {
    if let Ok(home) = std::env::var("HOME") {
        let repo_path = PathBuf::from(home).join(".vibeguard/repo-path");
        if let Ok(text) = std::fs::read_to_string(repo_path) {
            let path = text.trim();
            if !path.is_empty() {
                return PathBuf::from(path);
            }
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

struct SharedState {
    strategy: Box<dyn GateStrategy>,
    session: SessionState,
}

enum StdoutSignal {
    RequestStarted,
    RequestFinished,
    Done,
}

fn run_proxy(strategy: Box<dyn GateStrategy>, codex_command: &str) -> Result<(), Box<dyn Error>> {
    let mut child = Command::new("bash")
        .arg("-lc")
        .arg(codex_command)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;

    let child_stdin = child
        .stdin
        .take()
        .ok_or("failed to open app-server stdin")?;
    let child_stdout = child
        .stdout
        .take()
        .ok_or("failed to open app-server stdout")?;
    let child_stderr = child
        .stderr
        .take()
        .ok_or("failed to open app-server stderr")?;

    let shared = Arc::new(Mutex::new(SharedState {
        strategy,
        session: SessionState::default(),
    }));
    let child_stdin = Arc::new(Mutex::new(Some(child_stdin)));

    let stdin_shared = Arc::clone(&shared);
    let stdin_writer = Arc::clone(&child_stdin);
    let t_in = thread::spawn(move || {
        let reader = BufReader::new(std::io::stdin());
        for line in reader.lines().map_while(Result::ok) {
            if let Ok(message) = serde_json::from_str::<Value>(line.trim()) {
                if message.is_object() {
                    if let Ok(mut guard) = stdin_shared.lock() {
                        let mut session = std::mem::take(&mut guard.session);
                        guard.strategy.on_client_message(&message, &mut session);
                        guard.session = session;
                    }
                }
            }
            write_line_to_child(&stdin_writer, &line);
        }
    });

    let stdout_shared = Arc::clone(&shared);
    let stdout_writer = Arc::clone(&child_stdin);
    let (stdout_signal_tx, stdout_signal_rx) = mpsc::channel();
    let t_out = thread::spawn(move || {
        let reader = BufReader::new(child_stdout);
        for mut line in reader.lines().map_while(Result::ok) {
            let mut intercepted = false;
            if let Ok(message) = serde_json::from_str::<Value>(line.trim()) {
                if message.is_object() {
                    let method_is_string = message.get("method").and_then(Value::as_str).is_some();
                    if method_is_string && message.get("id").is_some() {
                        if stdout_signal_tx.send(StdoutSignal::RequestStarted).is_err() {
                            break;
                        }
                        let mut server_writes = Vec::new();
                        if let Ok(mut guard) = stdout_shared.lock() {
                            let mut session = std::mem::take(&mut guard.session);
                            let mut write_to_server = |obj: Value| {
                                server_writes.push(obj);
                            };
                            intercepted = guard.strategy.handle_server_request(
                                &message,
                                &mut session,
                                &mut write_to_server,
                            );
                            guard.session = session;
                        }
                        write_values_to_child(&stdout_writer, server_writes);
                        if stdout_signal_tx
                            .send(StdoutSignal::RequestFinished)
                            .is_err()
                        {
                            break;
                        }
                    } else if method_is_string {
                        if let Ok(mut guard) = stdout_shared.lock() {
                            let mut session = std::mem::take(&mut guard.session);
                            let next = guard.strategy.on_server_notification(message, &mut session);
                            guard.session = session;
                            line = next.to_string();
                        }
                    }
                }
            }
            if !intercepted {
                println!("{line}");
                let _ = std::io::stdout().flush();
            }
        }
        if stdout_signal_tx.send(StdoutSignal::Done).is_err() {
            return;
        }
    });

    let t_err = thread::spawn(move || {
        let reader = BufReader::new(child_stderr);
        for line in reader.lines().map_while(Result::ok) {
            eprintln!("{line}");
        }
    });

    let _ = t_in.join();
    // Client EOF may arrive while the server is still asking for a final
    // approval. Keep stdin open until in-flight server requests finish, then
    // give the child one quiet drain window before propagating EOF.
    if !wait_for_stdout_drain(&stdout_signal_rx, Duration::from_secs(2)) {
        close_child_stdin(&child_stdin);
    }
    let _ = t_out.join();
    close_child_stdin(&child_stdin);
    let _ = t_err.join();
    let status = child.wait()?;
    std::process::exit(status.code().unwrap_or(1));
}

fn wait_for_stdout_drain(signals: &mpsc::Receiver<StdoutSignal>, quiet_window: Duration) -> bool {
    let mut active_requests = 0usize;
    loop {
        match signals.recv_timeout(quiet_window) {
            Ok(StdoutSignal::RequestStarted) => {
                active_requests = active_requests.saturating_add(1);
            }
            Ok(StdoutSignal::RequestFinished) => {
                active_requests = active_requests.saturating_sub(1);
            }
            Ok(StdoutSignal::Done) => return true,
            Err(mpsc::RecvTimeoutError::Timeout) if active_requests == 0 => return false,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return true,
        }
    }
}

fn write_line_to_child(writer: &Arc<Mutex<Option<ChildStdin>>>, line: &str) {
    if let Ok(mut writer) = writer.lock() {
        if let Some(stdin) = writer.as_mut() {
            let _ = writeln!(stdin, "{line}");
            let _ = stdin.flush();
        }
    }
}

fn write_values_to_child(writer: &Arc<Mutex<Option<ChildStdin>>>, values: Vec<Value>) {
    if values.is_empty() {
        return;
    }
    if let Ok(mut writer) = writer.lock() {
        if let Some(stdin) = writer.as_mut() {
            for value in values {
                let _ = writeln!(stdin, "{value}");
            }
            let _ = stdin.flush();
        }
    }
}

fn close_child_stdin(writer: &Arc<Mutex<Option<ChildStdin>>>) {
    if let Ok(mut writer) = writer.lock() {
        let _ = writer.take();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_string()).collect()
    }

    #[test]
    fn parse_args_uses_vibeguard_defaults() {
        let args = parse_args(&[]).expect("default args should parse");

        assert_eq!(args.strategy, "vibeguard");
        assert_eq!(args.codex_command, "codex app-server");
        assert!(!args.repo_dir.as_os_str().is_empty());
    }

    #[test]
    fn parse_args_accepts_inline_and_separate_values() {
        let args = parse_args(&strings(&[
            "--repo-dir=/tmp/vibeguard",
            "--strategy",
            "noop",
            "--codex-command=codex app-server --json",
        ]))
        .expect("explicit args should parse");

        assert_eq!(args.repo_dir, PathBuf::from("/tmp/vibeguard"));
        assert_eq!(args.strategy, "noop");
        assert_eq!(args.codex_command, "codex app-server --json");
    }

    #[test]
    fn parse_args_rejects_unknown_args() {
        let err = parse_args(&strings(&["--missing"])).expect_err("unknown arg should fail");

        assert!(err.to_string().contains("unknown argument: --missing"));
    }

    #[test]
    fn stdout_drain_waits_for_in_flight_request() {
        let (tx, rx) = std::sync::mpsc::channel();
        assert!(tx.send(StdoutSignal::RequestStarted).is_ok());
        let finish_tx = tx.clone();
        let handle = thread::spawn(move || {
            thread::sleep(Duration::from_millis(30));
            assert!(finish_tx.send(StdoutSignal::RequestFinished).is_ok());
        });
        let started = std::time::Instant::now();

        assert!(!wait_for_stdout_drain(&rx, Duration::from_millis(5)));
        assert!(started.elapsed() >= Duration::from_millis(25));
        assert!(handle.join().is_ok());
    }

    #[test]
    fn stdout_drain_finishes_when_stdout_is_done() {
        let (tx, rx) = std::sync::mpsc::channel();
        assert!(tx.send(StdoutSignal::Done).is_ok());

        assert!(wait_for_stdout_drain(&rx, Duration::from_millis(5)));
    }
}
