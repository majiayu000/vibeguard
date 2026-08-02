mod common;

use common::{assert_output, bin, path_text, unique_temp_dir};
use std::fs;

#[test]
fn lock_lifecycle_commands_reject_invalid_arity() {
    let acquire = bin()
        .arg("setup-lock-acquire")
        .output()
        .expect("lock acquire command should run");
    assert_output(
        &acquire,
        1,
        "",
        "vibeguard-runtime error: Usage: vibeguard-runtime setup-lock-acquire <lock-dir> <pid> <nonce>\n",
    );
    let release = bin()
        .arg("setup-lock-release")
        .output()
        .expect("lock release command should run");
    assert_output(
        &release,
        1,
        "",
        "vibeguard-runtime error: Usage: vibeguard-runtime setup-lock-release <lock-dir> <pid> <nonce>\n",
    );
}

#[test]
fn atomic_lock_directory_acquire_and_release_round_trip() {
    let root = unique_temp_dir("setup-lock-round-trip");
    fs::create_dir_all(&root).expect("root should be created");
    let lock = root.join("setup.lock");
    let acquired = bin()
        .args(["setup-lock-acquire", &path_text(&lock), "42", "nonce"])
        .output()
        .expect("lock acquire should run");
    assert_output(&acquired, 0, "ACQUIRED\n", "");
    assert_eq!(
        fs::read_to_string(lock.join("owner")).expect("owner should be readable"),
        "pid=42\nnonce=nonce\n"
    );
    let released = bin()
        .args(["setup-lock-release", &path_text(&lock), "42", "nonce"])
        .output()
        .expect("lock release should run");
    assert_output(&released, 0, "RELEASED\n", "");
    assert!(!lock.exists());
    fs::remove_dir_all(root).expect("root should be removed");
}

#[test]
fn interrupted_lock_directory_transitions_never_leave_canonical_ownerless() {
    let root = unique_temp_dir("setup-lock-interrupted");
    fs::create_dir_all(&root).expect("root should be created");
    let lock = root.join("setup.lock");
    let interrupted_acquire = bin()
        .args(["setup-lock-acquire", &path_text(&lock), "42", "first"])
        .env("VIBEGUARD_TEST_SETUP_LOCK_ACQUIRE_BEFORE_RENAME", "1")
        .output()
        .expect("interrupted lock acquire should run");
    assert_eq!(interrupted_acquire.status.code(), Some(1));
    assert!(!lock.exists());

    assert_output(
        &bin()
            .args(["setup-lock-acquire", &path_text(&lock), "43", "second"])
            .output()
            .expect("retry acquire should run"),
        0,
        "ACQUIRED\n",
        "",
    );
    let interrupted_release = bin()
        .args(["setup-lock-release", &path_text(&lock), "43", "second"])
        .env("VIBEGUARD_TEST_SETUP_LOCK_RELEASE_AFTER_RENAME", "1")
        .output()
        .expect("interrupted lock release should run");
    assert_eq!(interrupted_release.status.code(), Some(1));
    assert!(!lock.exists());
    assert_output(
        &bin()
            .args(["setup-lock-acquire", &path_text(&lock), "44", "third"])
            .output()
            .expect("post-release retry acquire should run"),
        0,
        "ACQUIRED\n",
        "",
    );
    fs::remove_dir_all(root).expect("root should be removed");
}
