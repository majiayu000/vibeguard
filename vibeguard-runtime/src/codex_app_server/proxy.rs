use super::core::{GateStrategy, SessionState};
use serde_json::Value;
use std::error::Error;
use std::io::{self, BufRead, BufReader, Write};
use std::process::{ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

struct SharedState {
    strategy: Box<dyn GateStrategy>,
    session: SessionState,
}

enum StdoutSignal {
    RequestStarted,
    RequestFinished,
    Done,
}

type ChildInput = Arc<Mutex<Option<ChildStdin>>>;
type SharedSession = Arc<Mutex<SharedState>>;
type WorkerResult = io::Result<()>;

pub(super) fn run_proxy(
    strategy: Box<dyn GateStrategy>,
    codex_command: &str,
) -> Result<(), Box<dyn Error>> {
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
    let stdin_worker = thread::spawn(move || {
        proxy_client_input(
            BufReader::new(std::io::stdin()),
            &stdin_shared,
            &stdin_writer,
        )
    });

    let stdout_shared = Arc::clone(&shared);
    let stdout_writer = Arc::clone(&child_stdin);
    let (stdout_signal_tx, stdout_signal_rx) = mpsc::channel();
    let stdout_worker = thread::spawn(move || {
        let mut output = std::io::stdout();
        let result = proxy_server_output(
            BufReader::new(child_stdout),
            &mut output,
            &stdout_shared,
            &stdout_writer,
            &stdout_signal_tx,
        );
        combine_io_results(
            result,
            stdout_signal_tx.send(StdoutSignal::Done).map_err(|_| {
                io::Error::new(io::ErrorKind::BrokenPipe, "stdout drain receiver closed")
            }),
        )
    });

    let stderr_worker = thread::spawn(move || {
        let mut output = std::io::stderr();
        proxy_child_stderr(BufReader::new(child_stderr), &mut output)
    });

    let mut failures = Vec::new();
    let stdin_result = join_worker(stdin_worker, "stdin");
    if stdin_result.is_err() {
        record_failure(
            &mut failures,
            "close child stdin after input failure",
            close_child_stdin(&child_stdin),
        );
    }
    record_failure(&mut failures, "stdin worker", stdin_result);

    // Client EOF may arrive while the server is still asking for a final
    // approval. Keep stdin open until in-flight server requests finish, then
    // give the child one quiet drain window before propagating EOF.
    if !wait_for_stdout_drain(
        &stdout_signal_rx,
        Duration::from_secs(2),
        Duration::from_secs(30),
    ) {
        record_failure(
            &mut failures,
            "close child stdin after drain",
            close_child_stdin(&child_stdin),
        );
    }

    record_failure(
        &mut failures,
        "stdout worker",
        join_worker(stdout_worker, "stdout"),
    );
    record_failure(
        &mut failures,
        "close child stdin",
        close_child_stdin(&child_stdin),
    );
    record_failure(
        &mut failures,
        "stderr worker",
        join_worker(stderr_worker, "stderr"),
    );

    let status = child.wait()?;
    if !failures.is_empty() {
        if !status.success() {
            failures.push(format!("app-server exited with {status}"));
        }
        return Err(failures.join("; ").into());
    }

    std::process::exit(status.code().unwrap_or(1));
}

fn proxy_client_input<R: BufRead>(
    reader: R,
    shared: &SharedSession,
    writer: &ChildInput,
) -> WorkerResult {
    for line in reader.lines() {
        let line = line.map_err(|err| io_with_context(err, "read wrapper stdin"))?;
        if let Ok(message) = serde_json::from_str::<Value>(line.trim())
            && message.is_object()
        {
            let mut guard = shared.lock().map_err(|_| {
                io::Error::other("app-server session lock poisoned on client input")
            })?;
            let mut session = std::mem::take(&mut guard.session);
            guard.strategy.on_client_message(&message, &mut session);
            guard.session = session;
        }
        write_line_to_child(writer, &line)?;
    }
    Ok(())
}

fn proxy_server_output<R: BufRead, W: Write>(
    reader: R,
    output: &mut W,
    shared: &SharedSession,
    writer: &ChildInput,
    signals: &mpsc::Sender<StdoutSignal>,
) -> WorkerResult {
    for line in reader.lines() {
        let mut line = line.map_err(|err| io_with_context(err, "read app-server stdout"))?;
        let mut intercepted = false;
        if let Ok(message) = serde_json::from_str::<Value>(line.trim())
            && message.is_object()
        {
            let method_is_string = message.get("method").and_then(Value::as_str).is_some();
            if method_is_string && message.get("id").is_some() {
                send_signal(signals, StdoutSignal::RequestStarted)?;
                let request_result =
                    process_server_request(shared, writer, &message, &mut intercepted);
                let finish_result = send_signal(signals, StdoutSignal::RequestFinished);
                combine_io_results(request_result, finish_result)?;
            } else if method_is_string {
                let mut guard = shared.lock().map_err(|_| {
                    io::Error::other("app-server session lock poisoned on server notification")
                })?;
                let mut session = std::mem::take(&mut guard.session);
                let next = guard.strategy.on_server_notification(message, &mut session);
                guard.session = session;
                line = next.to_string();
            }
        }
        if !intercepted {
            writeln!(output, "{line}")?;
            output.flush()?;
        }
    }
    Ok(())
}

fn process_server_request(
    shared: &SharedSession,
    writer: &ChildInput,
    message: &Value,
    intercepted: &mut bool,
) -> WorkerResult {
    let mut server_writes = Vec::new();
    let mut guard = shared
        .lock()
        .map_err(|_| io::Error::other("app-server session lock poisoned on server request"))?;
    let mut session = std::mem::take(&mut guard.session);
    let mut write_to_server = |obj: Value| server_writes.push(obj);
    *intercepted =
        guard
            .strategy
            .handle_server_request(message, &mut session, &mut write_to_server);
    guard.session = session;
    drop(guard);
    write_values_to_child(writer, server_writes)
}

fn proxy_child_stderr<R: BufRead, W: Write>(reader: R, output: &mut W) -> WorkerResult {
    for line in reader.lines() {
        let line = line.map_err(|err| io_with_context(err, "read app-server stderr"))?;
        writeln!(output, "{line}")?;
        output.flush()?;
    }
    Ok(())
}

fn wait_for_stdout_drain(
    signals: &mpsc::Receiver<StdoutSignal>,
    quiet_window: Duration,
    max_total_wait: Duration,
) -> bool {
    let deadline = Instant::now() + max_total_wait;
    let mut active_requests = 0usize;
    loop {
        let now = Instant::now();
        if now >= deadline {
            return false;
        }
        let remaining = deadline - now;
        let recv_timeout = quiet_window.min(remaining);
        match signals.recv_timeout(recv_timeout) {
            Ok(StdoutSignal::RequestStarted) => {
                active_requests = active_requests.saturating_add(1);
            }
            Ok(StdoutSignal::RequestFinished) => {
                active_requests = active_requests.saturating_sub(1);
            }
            Ok(StdoutSignal::Done) => return true,
            Err(mpsc::RecvTimeoutError::Timeout) if active_requests == 0 => return false,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return false,
        }
    }
}

fn write_line_to_child(writer: &ChildInput, line: &str) -> WorkerResult {
    let mut writer = writer
        .lock()
        .map_err(|_| io::Error::other("app-server stdin lock poisoned"))?;
    let stdin = writer
        .as_mut()
        .ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "app-server stdin is closed"))?;
    writeln!(stdin, "{line}")?;
    stdin.flush()
}

fn write_values_to_child(writer: &ChildInput, values: Vec<Value>) -> WorkerResult {
    if values.is_empty() {
        return Ok(());
    }
    let mut writer = writer
        .lock()
        .map_err(|_| io::Error::other("app-server stdin lock poisoned"))?;
    let stdin = writer
        .as_mut()
        .ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "app-server stdin is closed"))?;
    for value in values {
        writeln!(stdin, "{value}")?;
    }
    stdin.flush()
}

fn close_child_stdin(writer: &ChildInput) -> WorkerResult {
    match writer.lock() {
        Ok(mut writer) => {
            writer.take();
            Ok(())
        }
        Err(poisoned) => {
            poisoned.into_inner().take();
            Err(io::Error::other(
                "app-server stdin lock poisoned while closing",
            ))
        }
    }
}

fn join_worker(worker: JoinHandle<WorkerResult>, name: &str) -> WorkerResult {
    worker
        .join()
        .map_err(|_| io::Error::other(format!("{name} worker panicked")))?
}

fn send_signal(sender: &mpsc::Sender<StdoutSignal>, signal: StdoutSignal) -> WorkerResult {
    sender
        .send(signal)
        .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "stdout drain receiver closed"))
}

fn combine_io_results(first: WorkerResult, second: WorkerResult) -> WorkerResult {
    match (first, second) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(err), Ok(())) | (Ok(()), Err(err)) => Err(err),
        (Err(first), Err(second)) => Err(io::Error::other(format!("{first}; {second}"))),
    }
}

fn record_failure(failures: &mut Vec<String>, context: &str, result: WorkerResult) {
    if let Err(err) = result {
        failures.push(format!("{context}: {err}"));
    }
}

fn io_with_context(err: io::Error, context: &str) -> io::Error {
    io::Error::new(err.kind(), format!("{context}: {err}"))
}

#[cfg(test)]
#[path = "proxy_tests.rs"]
mod tests;
