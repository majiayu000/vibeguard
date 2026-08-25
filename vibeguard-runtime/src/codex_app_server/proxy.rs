use super::core::{GateStrategy, SessionState};
use serde_json::Value;
use std::error::Error;
use std::io::{self, BufRead, BufReader, Write};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::process::{Child, ChildStdin, Command, Stdio};
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

#[derive(Clone, Copy)]
enum WorkerKind {
    Stdin,
    Stdout,
    Stderr,
}

enum ProxyEvent {
    Stdout(StdoutSignal),
    WorkerFinished(WorkerKind, WorkerResult),
}

struct DrainState {
    stdin_done_at: Option<Instant>,
    last_stdout_activity: Instant,
    active_requests: usize,
    stdout_drained: bool,
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
    let (event_tx, event_rx) = mpsc::channel();
    let _stdin_worker = spawn_worker(WorkerKind::Stdin, event_tx.clone(), move || {
        proxy_client_input(
            BufReader::new(std::io::stdin()),
            &stdin_shared,
            &stdin_writer,
        )
    });

    let stdout_shared = Arc::clone(&shared);
    let stdout_writer = Arc::clone(&child_stdin);
    let stdout_event_tx = event_tx.clone();
    let _stdout_worker = spawn_worker(WorkerKind::Stdout, event_tx.clone(), move || {
        let mut output = std::io::stdout();
        let result = proxy_server_output(
            BufReader::new(child_stdout),
            &mut output,
            &stdout_shared,
            &stdout_writer,
            &stdout_event_tx,
        );
        combine_io_results(
            result,
            stdout_event_tx
                .send(ProxyEvent::Stdout(StdoutSignal::Done))
                .map_err(|_| {
                    io::Error::new(io::ErrorKind::BrokenPipe, "stdout drain receiver closed")
                }),
        )
    });

    let _stderr_worker = spawn_worker(WorkerKind::Stderr, event_tx.clone(), move || {
        let mut output = std::io::stderr();
        proxy_child_stderr(BufReader::new(child_stderr), &mut output)
    });
    drop(event_tx);

    let mut drain = DrainState::new(Instant::now());
    let mut stdin_closed = false;
    let mut stdout_done = false;
    let mut stderr_done = false;

    while !stdout_done || !stderr_done {
        let event = match drain.next_wait(
            Instant::now(),
            Duration::from_secs(2),
            Duration::from_secs(30),
        ) {
            Some(timeout) => match event_rx.recv_timeout(timeout) {
                Ok(event) => Some(event),
                Err(mpsc::RecvTimeoutError::Timeout) => None,
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return abort_proxy(
                        &mut child,
                        &child_stdin,
                        vec!["proxy worker event channel disconnected".to_string()],
                    );
                }
            },
            None => match event_rx.recv() {
                Ok(event) => Some(event),
                Err(_) => {
                    return abort_proxy(
                        &mut child,
                        &child_stdin,
                        vec!["proxy worker event channel disconnected".to_string()],
                    );
                }
            },
        };

        if let Some(event) = event {
            match event {
                ProxyEvent::Stdout(signal) => drain.observe_stdout(signal, Instant::now()),
                ProxyEvent::WorkerFinished(kind, result) => {
                    if let Err(err) = result {
                        return abort_proxy(
                            &mut child,
                            &child_stdin,
                            vec![format!("{} worker: {err}", kind.label())],
                        );
                    }
                    match kind {
                        WorkerKind::Stdin => drain.observe_stdin_done(Instant::now()),
                        WorkerKind::Stdout => stdout_done = true,
                        WorkerKind::Stderr => stderr_done = true,
                    }
                }
            }
        }

        if !stdin_closed
            && (stdout_done
                || drain.should_close_stdin(
                    Instant::now(),
                    Duration::from_secs(2),
                    Duration::from_secs(30),
                ))
        {
            if let Err(err) = close_child_stdin(&child_stdin) {
                return abort_proxy(
                    &mut child,
                    &child_stdin,
                    vec![format!("close child stdin after drain: {err}")],
                );
            }
            stdin_closed = true;
        }
    }

    if !stdin_closed {
        close_child_stdin(&child_stdin)?;
    }

    let status = child.wait()?;
    std::process::exit(status.code().unwrap_or(1));
}

impl WorkerKind {
    fn label(self) -> &'static str {
        match self {
            Self::Stdin => "stdin",
            Self::Stdout => "stdout",
            Self::Stderr => "stderr",
        }
    }
}

impl DrainState {
    fn new(now: Instant) -> Self {
        Self {
            stdin_done_at: None,
            last_stdout_activity: now,
            active_requests: 0,
            stdout_drained: false,
        }
    }

    fn observe_stdin_done(&mut self, now: Instant) {
        self.stdin_done_at = Some(now);
        self.last_stdout_activity = now;
    }

    fn observe_stdout(&mut self, signal: StdoutSignal, now: Instant) {
        self.last_stdout_activity = now;
        match signal {
            StdoutSignal::RequestStarted => {
                self.active_requests = self.active_requests.saturating_add(1);
            }
            StdoutSignal::RequestFinished => {
                self.active_requests = self.active_requests.saturating_sub(1);
            }
            StdoutSignal::Done => self.stdout_drained = true,
        }
    }

    fn should_close_stdin(
        &self,
        now: Instant,
        quiet_window: Duration,
        max_total_wait: Duration,
    ) -> bool {
        self.stdout_drained
            || self.stdin_done_at.is_some_and(|started| {
                now.saturating_duration_since(started) >= max_total_wait
                    || (self.active_requests == 0
                        && now.saturating_duration_since(self.last_stdout_activity) >= quiet_window)
            })
    }

    fn next_wait(
        &self,
        now: Instant,
        quiet_window: Duration,
        max_total_wait: Duration,
    ) -> Option<Duration> {
        let started = self.stdin_done_at?;
        let max_remaining = max_total_wait.saturating_sub(now.saturating_duration_since(started));
        if self.active_requests > 0 {
            return Some(max_remaining);
        }
        let quiet_remaining =
            quiet_window.saturating_sub(now.saturating_duration_since(self.last_stdout_activity));
        Some(quiet_remaining.min(max_remaining))
    }
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
    signals: &mpsc::Sender<ProxyEvent>,
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

fn spawn_worker<F>(kind: WorkerKind, sender: mpsc::Sender<ProxyEvent>, worker: F) -> JoinHandle<()>
where
    F: FnOnce() -> WorkerResult + Send + 'static,
{
    thread::spawn(move || {
        let result = run_worker(kind.label(), worker);
        // A disconnected receiver means the coordinator already returned
        // through the process-level failure path, so no observer remains.
        drop(sender.send(ProxyEvent::WorkerFinished(kind, result)));
    })
}

fn run_worker<F>(name: &str, worker: F) -> WorkerResult
where
    F: FnOnce() -> WorkerResult,
{
    catch_unwind(AssertUnwindSafe(worker))
        .map_err(|_| io::Error::other(format!("{name} worker panicked")))?
}

fn abort_proxy(
    child: &mut Child,
    writer: &ChildInput,
    mut failures: Vec<String>,
) -> Result<(), Box<dyn Error>> {
    record_failure(
        &mut failures,
        "close child stdin after worker failure",
        close_child_stdin(writer),
    );

    let status = match child.try_wait() {
        Ok(Some(status)) => Some(status),
        Ok(None) => {
            record_failure(&mut failures, "terminate app-server", child.kill());
            match child.wait() {
                Ok(status) => Some(status),
                Err(err) => {
                    failures.push(format!("wait for app-server after failure: {err}"));
                    None
                }
            }
        }
        Err(err) => {
            failures.push(format!("inspect app-server after failure: {err}"));
            record_failure(&mut failures, "terminate app-server", child.kill());
            match child.wait() {
                Ok(status) => Some(status),
                Err(err) => {
                    failures.push(format!("wait for app-server after failure: {err}"));
                    None
                }
            }
        }
    };
    if let Some(status) = status
        && !status.success()
    {
        failures.push(format!("app-server exited with {status}"));
    }
    Err(failures.join("; ").into())
}

fn send_signal(sender: &mpsc::Sender<ProxyEvent>, signal: StdoutSignal) -> WorkerResult {
    sender
        .send(ProxyEvent::Stdout(signal))
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
