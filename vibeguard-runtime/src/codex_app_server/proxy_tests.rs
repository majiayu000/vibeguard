use super::*;
use crate::codex_app_server::core::NoopGateStrategy;
use std::io::Cursor;

fn shared_noop() -> SharedSession {
    Arc::new(Mutex::new(SharedState {
        strategy: Box::new(NoopGateStrategy),
        session: SessionState::default(),
    }))
}

#[test]
fn stdout_drain_waits_for_in_flight_request() {
    let started = Instant::now();
    let mut drain = DrainState::new(started);
    drain.observe_stdout(StdoutSignal::RequestStarted, started);
    drain.observe_stdin_done(started);

    assert!(!drain.should_close_stdin(
        started + Duration::from_millis(30),
        Duration::from_millis(5),
        Duration::from_secs(5),
    ));
    drain.observe_stdout(
        StdoutSignal::RequestFinished,
        started + Duration::from_millis(30),
    );
    assert!(!drain.should_close_stdin(
        started + Duration::from_millis(34),
        Duration::from_millis(5),
        Duration::from_secs(5),
    ));
    assert!(drain.should_close_stdin(
        started + Duration::from_millis(35),
        Duration::from_millis(5),
        Duration::from_secs(5),
    ));
}

#[test]
fn stdout_drain_finishes_when_stdout_is_done() {
    let started = Instant::now();
    let mut drain = DrainState::new(started);
    drain.observe_stdout(StdoutSignal::Done, started);

    assert!(drain.should_close_stdin(started, Duration::from_millis(5), Duration::from_secs(5),));
}

#[test]
fn stdout_drain_times_out_when_request_never_finishes() {
    let started = Instant::now();
    let mut drain = DrainState::new(started);
    drain.observe_stdout(StdoutSignal::RequestStarted, started);
    drain.observe_stdin_done(started);

    assert!(drain.should_close_stdin(
        started + Duration::from_millis(50),
        Duration::from_millis(5),
        Duration::from_millis(50)
    ));
}

#[test]
fn server_output_write_failures_are_returned() {
    struct FailingWriter;
    impl Write for FailingWriter {
        fn write(&mut self, _buf: &[u8]) -> io::Result<usize> {
            Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "fixture output closed",
            ))
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    let writer = Arc::new(Mutex::new(None));
    let (tx, _rx) = mpsc::channel();
    let err = proxy_server_output(
        Cursor::new(b"plain output\n"),
        &mut FailingWriter,
        &shared_noop(),
        &writer,
        &tx,
    )
    .unwrap_err();

    assert_eq!(err.kind(), io::ErrorKind::BrokenPipe);
    assert!(err.to_string().contains("fixture output closed"));
}

#[test]
fn server_output_read_failures_are_returned() {
    let writer = Arc::new(Mutex::new(None));
    let (tx, _rx) = mpsc::channel();
    let err = proxy_server_output(
        Cursor::new(vec![0xff, b'\n']),
        &mut Vec::new(),
        &shared_noop(),
        &writer,
        &tx,
    )
    .unwrap_err();

    assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    assert!(err.to_string().contains("read app-server stdout"));
}

#[test]
fn poisoned_session_lock_fails_closed() {
    let shared = shared_noop();
    let poison = Arc::clone(&shared);
    assert!(
        thread::spawn(move || {
            let _guard = poison.lock().unwrap();
            panic!("poison fixture");
        })
        .join()
        .is_err()
    );

    let writer = Arc::new(Mutex::new(None));
    let err = proxy_client_input(Cursor::new(b"{}\n"), &shared, &writer).unwrap_err();

    assert!(err.to_string().contains("session lock poisoned"));
}

#[test]
fn worker_panics_are_returned() {
    let err = run_worker("fixture", || -> WorkerResult { panic!("worker fixture") }).unwrap_err();

    assert!(err.to_string().contains("fixture worker panicked"));
}
