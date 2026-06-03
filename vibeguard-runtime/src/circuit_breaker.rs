use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
#[cfg(unix)]
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::time_utils::now_unix_secs;

type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CircuitStateName {
    Closed,
    Open,
    HalfOpen,
}

impl CircuitStateName {
    fn as_str(self) -> &'static str {
        match self {
            Self::Closed => "CLOSED",
            Self::Open => "OPEN",
            Self::HalfOpen => "HALF-OPEN",
        }
    }

    fn parse(value: &str) -> Self {
        match value {
            "OPEN" => Self::Open,
            "HALF-OPEN" => Self::HalfOpen,
            _ => Self::Closed,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct CircuitState {
    state: CircuitStateName,
    blocks: u64,
    last_block: u64,
    session: String,
}

impl Default for CircuitState {
    fn default() -> Self {
        Self {
            state: CircuitStateName::Closed,
            blocks: 0,
            last_block: 0,
            session: String::new(),
        }
    }
}

pub fn run(args: &[String]) -> Result {
    if args.len() != 7 {
        return Err("Usage: vibeguard-runtime circuit-breaker <check|record-block|record-pass> <hook> <state-file> <lock-file> <threshold> <cooldown-seconds> <lock-timeout-seconds>".into());
    }

    let action = args[0].as_str();
    let hook = args[1].as_str();
    let state_file = Path::new(&args[2]);
    let lock_file = Path::new(&args[3]);
    let threshold = parse_u64(&args[4], "threshold")?;
    let cooldown = parse_u64(&args[5], "cooldown-seconds")?;
    let lock_timeout = parse_u64(&args[6], "lock-timeout-seconds")?;
    let session = std::env::var("VIBEGUARD_SESSION_ID").unwrap_or_default();

    let _lock = CircuitLock::acquire(lock_file, lock_timeout)?;
    let mut state = load_state(state_file)?;
    let dirty = apply_session_reset(&mut state, &session);

    match action {
        "check" => run_check(hook, state_file, &mut state, &session, cooldown, dirty),
        "record-block" => {
            run_record_block(hook, state_file, &mut state, &session, threshold, cooldown)
        }
        "record-pass" => run_record_pass(state_file, &mut state, &session, dirty),
        _ => Err(format!("unknown circuit-breaker action: {action}").into()),
    }
}

fn parse_u64(value: &str, name: &str) -> Result<u64> {
    value
        .parse::<u64>()
        .map_err(|_| format!("invalid circuit breaker {name}: {value}").into())
}

fn run_check(
    _hook: &str,
    state_file: &Path,
    state: &mut CircuitState,
    session: &str,
    cooldown: u64,
    dirty: bool,
) -> Result {
    let now = now_unix_secs();

    match state.state {
        CircuitStateName::Closed => {
            if dirty {
                save_state(state_file, state, session)?;
            }
            println!("RUN");
        }
        CircuitStateName::Open => {
            let elapsed = now.saturating_sub(state.last_block);
            if elapsed >= cooldown {
                state.state = CircuitStateName::HalfOpen;
                state.last_block = now;
                save_state(state_file, state, session)?;
                println!("RUN");
            } else {
                let remaining = cooldown - elapsed;
                println!("AUTO_PASS");
                println!(
                    "CB OPEN: auto-pass ({remaining}s remaining, {} consecutive blocks)",
                    state.blocks
                );
            }
        }
        CircuitStateName::HalfOpen => {
            println!("AUTO_PASS");
            println!(
                "CB HALF-OPEN: probe in-flight, auto-passing ({} prior blocks)",
                state.blocks
            );
        }
    }

    Ok(())
}

fn run_record_block(
    _hook: &str,
    state_file: &Path,
    state: &mut CircuitState,
    session: &str,
    threshold: u64,
    cooldown: u64,
) -> Result {
    state.blocks = state.blocks.saturating_add(1);
    state.last_block = now_unix_secs();

    if state.state == CircuitStateName::HalfOpen || state.blocks >= threshold {
        state.state = CircuitStateName::Open;
        save_state(state_file, state, session)?;
        println!("OPENED");
        println!(
            "CB tripped OPEN: {} consecutive blocks, cooldown {cooldown}s",
            state.blocks
        );
    } else {
        save_state(state_file, state, session)?;
        println!("RECORDED");
    }

    Ok(())
}

fn run_record_pass(
    state_file: &Path,
    state: &mut CircuitState,
    session: &str,
    dirty: bool,
) -> Result {
    if state.state != CircuitStateName::Closed || state.blocks > 0 || dirty {
        state.state = CircuitStateName::Closed;
        state.blocks = 0;
        state.last_block = 0;
        save_state(state_file, state, session)?;
    }
    println!("RECORDED");
    Ok(())
}

fn apply_session_reset(state: &mut CircuitState, session: &str) -> bool {
    if !session.is_empty() && !state.session.is_empty() && state.session != session {
        *state = CircuitState::default();
        true
    } else {
        false
    }
}

fn load_state(path: &Path) -> Result<CircuitState> {
    if !path.exists() {
        return Ok(CircuitState::default());
    }

    let content = fs::read_to_string(path)
        .map_err(|_| format!("failed to read circuit breaker state: {}", path.display()))?;
    let mut state = CircuitState::default();

    for line in content.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key {
            "CB_STATE" => state.state = CircuitStateName::parse(value),
            "CB_BLOCKS" => {
                if let Ok(blocks) = value.parse::<u64>() {
                    state.blocks = blocks;
                }
            }
            "CB_LAST_BLOCK" => {
                if let Ok(last_block) = value.parse::<u64>() {
                    state.last_block = last_block;
                }
            }
            "CB_SESSION" => {
                if value
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'=' | b'-'))
                {
                    state.session = value.to_string();
                }
            }
            _ => {}
        }
    }

    Ok(state)
}

fn save_state(path: &Path, state: &CircuitState, session: &str) -> Result {
    let Some(parent) = path.parent() else {
        return Err(format!(
            "failed to create circuit breaker state directory: {}",
            path.display()
        )
        .into());
    };
    fs::create_dir_all(parent).map_err(|_| {
        format!(
            "failed to create circuit breaker state directory: {}",
            parent.display()
        )
    })?;

    let tmp_file = path.with_extension(format!(
        "{}.tmp.{}",
        path.extension().and_then(|s| s.to_str()).unwrap_or("cb"),
        std::process::id()
    ));
    write_state_file(&tmp_file, state, session)?;
    fs::rename(&tmp_file, path).map_err(|_| {
        if let Err(remove_err) = fs::remove_file(&tmp_file) {
            if remove_err.kind() != io::ErrorKind::NotFound {
                eprintln!(
                    "VIBEGUARD ERROR: failed to remove circuit breaker temp file: {}",
                    tmp_file.display()
                );
            }
        }
        format!(
            "failed to persist circuit breaker state: {}",
            path.display()
        )
    })?;
    Ok(())
}

fn write_state_file(path: &Path, state: &CircuitState, session: &str) -> Result {
    let mut file = File::create(path).map_err(|_| {
        format!(
            "failed to write circuit breaker state temp file: {}",
            path.display()
        )
    })?;
    write!(
        file,
        "CB_STATE={}\nCB_BLOCKS={}\nCB_LAST_BLOCK={}\nCB_SESSION={}\n",
        state.state.as_str(),
        state.blocks,
        state.last_block,
        session
    )
    .map_err(|_| {
        format!(
            "failed to write circuit breaker state temp file: {}",
            path.display()
        )
    })?;
    Ok(())
}

struct CircuitLock {
    #[cfg(unix)]
    file: File,
    lock_dir: Option<PathBuf>,
}

impl CircuitLock {
    fn acquire(lock_file: &Path, timeout_seconds: u64) -> Result<Self> {
        if let Some(parent) = lock_file.parent() {
            fs::create_dir_all(parent).map_err(|_| {
                format!(
                    "failed to create circuit breaker lock directory: {}",
                    parent.display()
                )
            })?;
        }

        #[cfg(unix)]
        {
            let file = OpenOptions::new()
                .create(true)
                .write(true)
                .open(lock_file)
                .map_err(|_| {
                    format!(
                        "failed to open circuit breaker lock file: {}",
                        lock_file.display()
                    )
                })?;
            acquire_unix_flock(&file, lock_file, timeout_seconds)?;
            let lock_dir = mkdir_lock_dir(lock_file);
            acquire_mkdir_lock(&lock_dir, lock_file, timeout_seconds)?;
            Ok(Self {
                file,
                lock_dir: Some(lock_dir),
            })
        }

        #[cfg(not(unix))]
        {
            let lock_dir = mkdir_lock_dir(lock_file);
            acquire_mkdir_lock(&lock_dir, lock_file, timeout_seconds)?;
            Ok(Self {
                lock_dir: Some(lock_dir),
            })
        }
    }
}

fn mkdir_lock_dir(lock_file: &Path) -> PathBuf {
    let mut lock_dir = lock_file.as_os_str().to_os_string();
    lock_dir.push(".d");
    PathBuf::from(lock_dir)
}

#[cfg(unix)]
fn acquire_unix_flock(file: &File, lock_file: &Path, timeout_seconds: u64) -> Result {
    let deadline = Instant::now() + Duration::from_secs(timeout_seconds);
    loop {
        let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if rc == 0 {
            return Ok(());
        }

        let err = io::Error::last_os_error();
        let would_block = matches!(err.raw_os_error(), Some(libc::EWOULDBLOCK));
        if !would_block {
            return Err(format!(
                "failed to lock circuit breaker file: {}",
                lock_file.display()
            )
            .into());
        }
        if timeout_seconds == 0 || Instant::now() >= deadline {
            return Err(format!(
                "circuit breaker lock timeout for {} after {}s",
                lock_file.display(),
                timeout_seconds
            )
            .into());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn acquire_mkdir_lock(lock_dir: &Path, lock_file: &Path, timeout_seconds: u64) -> Result {
    let max_attempts = (timeout_seconds * 10).max(1);
    for attempt in 0..max_attempts {
        match fs::create_dir(lock_dir) {
            Ok(()) => return Ok(()),
            Err(err) if err.kind() == io::ErrorKind::AlreadyExists => {
                if attempt + 1 < max_attempts {
                    std::thread::sleep(Duration::from_millis(100));
                }
            }
            Err(_) => {
                return Err(format!(
                    "failed to lock circuit breaker file: {}",
                    lock_file.display()
                )
                .into());
            }
        }
    }
    Err(format!(
        "circuit breaker lock timeout for {} after {}s",
        lock_file.display(),
        timeout_seconds
    )
    .into())
}

impl Drop for CircuitLock {
    fn drop(&mut self) {
        #[cfg(unix)]
        unsafe {
            let unlock_rc = libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
            if unlock_rc != 0 {
                eprintln!("VIBEGUARD ERROR: failed to unlock circuit breaker lock");
            }
        }

        #[cfg(not(unix))]
        {}

        if let Some(lock_dir) = &self.lock_dir {
            if let Err(err) = fs::remove_dir(lock_dir) {
                if err.kind() != io::ErrorKind::NotFound {
                    eprintln!(
                        "VIBEGUARD ERROR: failed to remove circuit breaker mkdir lock: {}",
                        lock_dir.display()
                    );
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_state(label: &str) -> (PathBuf, PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "vibeguard-cb-{label}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        (dir.join("hook.cb"), dir.join("hook.cb.lock"))
    }

    #[test]
    fn mkdir_lock_dir_matches_shell_fallback_path() {
        assert_eq!(
            mkdir_lock_dir(Path::new("/tmp/example.cb.lock")),
            PathBuf::from("/tmp/example.cb.lock.d")
        );
    }

    #[test]
    fn load_state_ignores_unsafe_values() -> Result {
        let (state_file, _) = temp_state("unsafe-values");
        let Some(parent) = state_file.parent() else {
            return Err("test state file has no parent directory".into());
        };
        fs::create_dir_all(parent)?;
        fs::write(
            &state_file,
            "CB_STATE=BOGUS\nCB_BLOCKS=abc\nCB_LAST_BLOCK=7\nCB_SESSION=bad session!\n",
        )?;

        let state = load_state(&state_file)?;
        assert_eq!(state.state, CircuitStateName::Closed);
        assert_eq!(state.blocks, 0);
        assert_eq!(state.last_block, 7);
        assert_eq!(state.session, "");

        if let Err(err) = fs::remove_dir_all(parent) {
            eprintln!("test cleanup failed: {err}");
        }
        Ok(())
    }
}
