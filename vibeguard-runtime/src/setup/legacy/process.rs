use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

pub(super) enum CommandOutput {
    Success(std::process::Output),
    Missing,
    TimedOut(String),
    Failed(String),
}

pub(super) fn command_output(program: &str, args: &[&str], timeout: Duration) -> CommandOutput {
    let child = match Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return CommandOutput::Missing;
        }
        Err(error) => return CommandOutput::Failed(error.to_string()),
    };
    let pid = child.id();
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        drop(sender.send(child.wait_with_output()));
    });
    match receiver.recv_timeout(timeout) {
        Ok(Ok(output)) => CommandOutput::Success(output),
        Ok(Err(error)) => CommandOutput::Failed(error.to_string()),
        Err(_) => {
            let kill = Command::new("kill")
                .args(["-s", "TERM", &pid.to_string()])
                .status();
            let reaped = receiver.recv_timeout(Duration::from_secs(2));
            let detail = match (kill, reaped) {
                (Err(error), _) => {
                    format!("command timed out and could not be stopped: {error}")
                }
                (Ok(status), _) if !status.success() => {
                    format!("command timed out and kill exited {status}")
                }
                (_, Err(_)) => "command timed out and was still running after TERM".into(),
                _ => "command timed out".into(),
            };
            CommandOutput::TimedOut(detail)
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
pub(super) fn account_home() -> Result<PathBuf, String> {
    #[cfg(target_os = "macos")]
    {
        let user = command_text("id", &["-un"])?;
        let text = command_text(
            "dscl",
            &[".", "-read", &format!("/Users/{user}"), "NFSHomeDirectory"],
        )?;
        let home = text
            .lines()
            .find_map(|line| line.strip_prefix("NFSHomeDirectory:"))
            .map(str::trim)
            .filter(|home| !home.is_empty())
            .ok_or_else(|| "dscl did not return NFSHomeDirectory".to_string())?;
        Ok(PathBuf::from(home))
    }
    #[cfg(target_os = "linux")]
    {
        let uid = command_text("id", &["-u"])?;
        let text = command_text("getent", &["passwd", &uid])?;
        let home = text
            .split(':')
            .nth(5)
            .filter(|home| !home.is_empty())
            .ok_or_else(|| "passwd entry has no home".to_string())?;
        Ok(PathBuf::from(home))
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn command_text(program: &str, args: &[&str]) -> Result<String, String> {
    match command_output(program, args, Duration::from_secs(5)) {
        CommandOutput::Success(output) if output.status.success() => {
            String::from_utf8(output.stdout)
                .map(|text| text.trim().to_string())
                .map_err(|_| format!("{program} output is not UTF-8"))
        }
        CommandOutput::Success(output) => Err(format!(
            "{program} exited {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        )),
        CommandOutput::Missing => Err(format!("{program} is unavailable")),
        CommandOutput::TimedOut(detail) => Err(detail),
        CommandOutput::Failed(detail) => Err(detail),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn timed_out_command_is_not_an_empty_result() {
        let started = std::time::Instant::now();
        let output = command_output("sleep", &["5"], Duration::from_millis(200));
        assert!(matches!(output, CommandOutput::TimedOut(_)));
        assert!(started.elapsed() < Duration::from_secs(3));
    }
}
