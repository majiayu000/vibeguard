#![cfg(any(target_os = "macos", target_os = "linux"))]

use std::fs::{self, File};
use std::os::unix::fs::{MetadataExt, PermissionsExt, fchown};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

const BIN: &str = env!("CARGO_BIN_EXE_vibeguard-runtime");
const ATTRIBUTE: &str = "user.vibeguard-test";
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "vibeguard-metadata-{}-{}",
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

fn invoke(home: &Path, action: &str, host: &str) -> Output {
    Command::new(BIN)
        .args([action, host, "--home"])
        .arg(home)
        .output()
        .unwrap()
}

fn success(output: Output) {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[cfg(target_os = "macos")]
fn add_acl(path: &Path) {
    success(
        Command::new("/bin/chmod")
            .args(["+a", "everyone allow read"])
            .arg(path)
            .output()
            .unwrap(),
    );
}

#[cfg(target_os = "macos")]
fn acl(path: &Path) -> Vec<u8> {
    let output = Command::new("/bin/ls")
        .arg("-le")
        .arg(path)
        .env("LC_ALL", "C")
        .output()
        .unwrap();
    assert!(output.status.success());
    output
        .stdout
        .splitn(2, |byte| *byte == b'\n')
        .nth(1)
        .unwrap_or_default()
        .to_vec()
}

#[cfg(target_os = "linux")]
fn add_acl(path: &Path) {
    // Linux uapi/posix_acl_xattr.h: version followed by little-endian
    // (tag, permissions, id) entries. Include a named user to require an ACL.
    let mut value = 2_u32.to_le_bytes().to_vec();
    for (tag, permissions, id) in [
        (1_u16, 6_u16, u32::MAX),
        (2, 4, 65534),
        (4, 4, u32::MAX),
        (16, 4, u32::MAX),
        (32, 0, u32::MAX),
    ] {
        value.extend(tag.to_le_bytes());
        value.extend(permissions.to_le_bytes());
        value.extend(id.to_le_bytes());
    }
    xattr::set(path, "system.posix_acl_access", &value).unwrap();
}

#[cfg(target_os = "linux")]
fn acl(path: &Path) -> Vec<u8> {
    xattr::get(path, "system.posix_acl_access")
        .unwrap()
        .unwrap_or_default()
}

fn use_alternate_group(path: &Path) {
    let metadata = fs::metadata(path).unwrap();
    let groups = Command::new("id").arg("-G").output().unwrap();
    assert!(groups.status.success());
    let group = String::from_utf8(groups.stdout)
        .unwrap()
        .split_whitespace()
        .map(|group| group.parse::<u32>().unwrap())
        .find(|group| *group != metadata.gid())
        .or_else(|| (metadata.uid() == 0).then_some(1));
    if let Some(group) = group {
        fchown(File::open(path).unwrap(), None, Some(group)).unwrap();
    }
}

#[test]
fn install_reinstall_and_uninstall_preserve_user_metadata() {
    for host in ["claude", "codex"] {
        let home = Temp::new();
        let host_dir = home.0.join(format!(".{host}"));
        fs::create_dir(&host_dir).unwrap();
        let config = host_dir.join(if host == "claude" {
            "settings.json"
        } else {
            "hooks.json"
        });
        let instructions = host_dir.join(if host == "claude" {
            "CLAUDE.md"
        } else {
            "AGENTS.md"
        });
        fs::write(&config, "{\"user_setting\": true}\n").unwrap();
        fs::write(&instructions, "# User notes\n").unwrap();
        let feature_config = host_dir.join("config.toml");
        let mut files = vec![&config, &instructions];
        if host == "codex" {
            fs::write(
                &feature_config,
                "# user setting\n[features]\nhooks = false\n",
            )
            .unwrap();
            files.push(&feature_config);
        }
        for path in &files {
            use_alternate_group(path);
            fs::set_permissions(path, fs::Permissions::from_mode(0o640)).unwrap();
            xattr::set(path, ATTRIBUTE, b"preserve-me").unwrap();
            add_acl(path);
        }
        let before: Vec<_> = files
            .iter()
            .map(|path| (fs::metadata(path).unwrap(), acl(path)))
            .collect();
        for action in ["install", "install", "uninstall"] {
            success(invoke(&home.0, action, host));
            if host == "codex" {
                let text = fs::read_to_string(&feature_config).unwrap();
                assert!(text.contains("# user setting"));
                assert!(text.contains("hooks = true"));
            }
            for (path, (metadata, expected_acl)) in files.iter().zip(&before) {
                let actual = fs::metadata(path).unwrap();
                assert_eq!(
                    (actual.uid(), actual.gid(), actual.mode()),
                    (metadata.uid(), metadata.gid(), metadata.mode())
                );
                assert_eq!(
                    xattr::get(path, ATTRIBUTE).unwrap().unwrap(),
                    b"preserve-me"
                );
                assert_eq!(&acl(path), expected_acl);
            }
        }
        assert_eq!(fs::read_to_string(instructions).unwrap(), "# User notes\n");
    }
}

#[test]
fn read_only_mode_does_not_prevent_metadata_copy() {
    let home = Temp::new();
    let host_dir = home.0.join(".codex");
    fs::create_dir(&host_dir).unwrap();
    let config = host_dir.join("hooks.json");
    fs::write(&config, "{}\n").unwrap();
    xattr::set(&config, ATTRIBUTE, b"read-only").unwrap();
    add_acl(&config);
    fs::set_permissions(&config, fs::Permissions::from_mode(0o400)).unwrap();
    let expected_acl = acl(&config);
    success(invoke(&home.0, "install", "codex"));
    assert_eq!(fs::metadata(&config).unwrap().mode() & 0o777, 0o400);
    assert_eq!(
        xattr::get(&config, ATTRIBUTE).unwrap().unwrap(),
        b"read-only"
    );
    assert_eq!(acl(&config), expected_acl);
}

#[test]
fn replacement_does_not_acquire_an_inherited_acl() {
    let home = Temp::new();
    let host_dir = home.0.join(".codex");
    fs::create_dir(&host_dir).unwrap();
    let config = host_dir.join("hooks.json");
    fs::write(&config, "{}\n").unwrap();
    let original_acl = acl(&config);
    #[cfg(target_os = "macos")]
    success(
        Command::new("/bin/chmod")
            .args(["+a", "everyone allow read,file_inherit"])
            .arg(&host_dir)
            .output()
            .unwrap(),
    );
    #[cfg(target_os = "linux")]
    {
        add_acl(&host_dir);
        fs::set_permissions(&host_dir, fs::Permissions::from_mode(0o750)).unwrap();
        let default_acl = acl(&host_dir);
        xattr::set(&host_dir, "system.posix_acl_default", &default_acl).unwrap();
    }
    success(invoke(&home.0, "install", "codex"));
    assert_eq!(acl(&config), original_acl);
}

#[cfg(target_os = "macos")]
#[test]
fn metadata_write_error_preserves_original_and_cleans_temporary_file() {
    let home = Temp::new();
    let host_dir = home.0.join(".codex");
    fs::create_dir(&host_dir).unwrap();
    let config = host_dir.join("hooks.json");
    fs::write(&config, "{}\n").unwrap();
    xattr::set(&config, ATTRIBUTE, b"original").unwrap();
    success(
        Command::new("/bin/chmod")
            .args(["+a", "everyone deny writeextattr,file_inherit"])
            .arg(&host_dir)
            .output()
            .unwrap(),
    );
    let inode = fs::metadata(&config).unwrap().ino();
    let output = invoke(&home.0, "install", "codex");
    // Remove the directory's inherited restriction for cleanup.
    success(
        Command::new("/bin/chmod")
            .arg("-N")
            .arg(&host_dir)
            .output()
            .unwrap(),
    );
    assert_eq!(output.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stderr).contains("could not preserve metadata"));
    assert_eq!(fs::metadata(&config).unwrap().ino(), inode);
    assert_eq!(fs::read(&config).unwrap(), b"{}\n");
    assert_eq!(
        xattr::get(&config, ATTRIBUTE).unwrap().unwrap(),
        b"original"
    );
    assert_eq!(fs::read_dir(host_dir).unwrap().count(), 1);
}
