use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

const BIN: &str = env!("CARGO_BIN_EXE_vibeguard-runtime");
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "vibeguard-v1-migration-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.0) {
            if std::thread::panicking() {
                eprintln!("test cleanup failed: {error}");
            } else {
                panic!("test cleanup failed: {error}");
            }
        }
    }
}
fn invoke(args: &[&str]) -> Output {
    Command::new(BIN).args(args).output().unwrap()
}
fn success(output: &Output) {
    assert!(
        output.status.success(),
        "stdout={}\nstderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn explicit_claude_v1_migration_previews_backs_up_and_preserves_other_hooks() {
    let temp = Temp::new();
    let home = temp.0.to_str().unwrap();
    fs::create_dir(temp.0.join(".claude")).unwrap();
    let settings = temp.0.join(".claude/settings.json");
    let remem =
        json!({"type":"command","command":"remem observe --host claude-code","timeout":120});
    let old = json!({"theme":"dark","hooks":{
        "PreToolUse":[{"matcher":"Bash","custom":"kept","hooks":[
            {"type":"command","command":"env VIBEGUARD_FOO=1 /Users/old/.vibeguard/run-hook.sh pre-bash-guard.sh"},
            remem.clone()
        ]}],
        "PostToolUse":[{"matcher":"Edit","hooks":[
            {"type":"command","command":"bash '/Users/old user/.vibeguard/run-hook.sh' post-edit-guard.sh"},
            {"type":"command","command":"bash '/Users/old user/.vibeguard/run-hook.sh' post-edit-guard.sh"}
        ]},{"hooks":[]}],
        "Stop":[{"hooks":[remem.clone()]}]
    }}).to_string();
    fs::write(&settings, &old).unwrap();
    let preview = invoke(&[
        "install",
        "claude",
        "--home",
        home,
        "--migrate-v1-hooks",
        "--dry-run",
    ]);
    success(&preview);
    let preview: Value = serde_json::from_slice(&preview.stdout).unwrap();
    assert!(preview.to_string().contains("remove_v1_hooks"));
    assert_eq!(fs::read_to_string(&settings).unwrap(), old);
    assert!(!temp.0.join(".vibeguard").exists());
    let output = invoke(&["install", "claude", "--home", home, "--migrate-v1-hooks"]);
    success(&output);
    let result: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(result["removed_v1_hooks"], 3);
    let backup = Path::new(result["migration_backup"].as_str().unwrap());
    assert_eq!(fs::read_to_string(backup).unwrap(), old);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(backup).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    let migrated: Value = serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
    assert_eq!(migrated["theme"], "dark");
    assert_eq!(migrated["hooks"]["PreToolUse"][0]["custom"], "kept");
    assert_eq!(migrated["hooks"]["PreToolUse"][0]["hooks"], json!([remem]));
    assert_eq!(migrated["hooks"]["PostToolUse"][0]["hooks"], json!([]));
    assert_eq!(migrated["hooks"]["Stop"], json!([{"hooks":[remem]}]));
    let before = fs::read(&settings).unwrap();
    let second = invoke(&["install", "claude", "--home", home, "--migrate-v1-hooks"]);
    success(&second);
    let second: Value = serde_json::from_slice(&second.stdout).unwrap();
    assert_eq!(second["removed_v1_hooks"], 0);
    assert!(second["migration_backup"].is_null());
    assert_eq!(fs::read(&settings).unwrap(), before);
}

#[test]
fn claude_v1_migration_is_opt_in_and_rejects_other_actions() {
    let temp = Temp::new();
    let home = temp.0.to_str().unwrap();
    fs::create_dir(temp.0.join(".claude")).unwrap();
    let settings = temp.0.join(".claude/settings.json");
    let old = json!({"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash /u/.vibeguard/run-hook.sh pre-bash-guard.sh"}]}]}});
    fs::write(&settings, old.to_string()).unwrap();
    for args in [
        vec!["status", "claude"],
        vec!["uninstall", "claude"],
        vec!["install", "codex"],
        vec!["install", "git"],
    ] {
        let mut args = args;
        args.extend(["--home", home, "--migrate-v1-hooks"]);
        assert_eq!(invoke(&args).status.code(), Some(2));
        assert!(!temp.0.join(".vibeguard").exists());
    }
    success(&invoke(&["install", "claude", "--home", home]));
    let after: Value = serde_json::from_str(&fs::read_to_string(settings).unwrap()).unwrap();
    assert_eq!(
        after["hooks"]["PreToolUse"][0],
        old["hooks"]["PreToolUse"][0]
    );
}
