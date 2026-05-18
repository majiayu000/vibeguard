#!/usr/bin/env python3
"""Safely discard enumerated Git changes after explicit authorization."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
from datetime import datetime, timezone
import shutil
import subprocess
import sys


CONFIRM_PHRASE = "discard listed changes"
CONFIRM_TOKEN = "discard-listed-changes"
IGNORED_CONFIRM_PHRASE = "discard ignored secret-like files"
IGNORED_CONFIRM_TOKEN = "discard-ignored-secret-like-files"


def run_git(repo: Path | None, args: list[str], check: bool = True) -> subprocess.CompletedProcess[bytes]:
    cmd = ["git"]
    if repo is not None:
        cmd.extend(["-C", str(repo)])
    cmd.extend(args)
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if check and proc.returncode != 0:
        err = proc.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(err or f"git {' '.join(args)} failed")
    return proc


def git_paths(repo: Path, args: list[str]) -> list[str]:
    out = run_git(repo, args).stdout
    return sorted({os.fsdecode(part) for part in out.split(b"\0") if part})


def repo_root() -> Path:
    proc = run_git(None, ["rev-parse", "--show-toplevel"], check=False)
    if proc.returncode != 0:
        raise RuntimeError("not inside a Git work tree")
    return Path(proc.stdout.decode("utf-8", "replace").strip()).resolve()


def has_head(repo: Path) -> bool:
    return run_git(repo, ["rev-parse", "--verify", "HEAD"], check=False).returncode == 0


def path_in_head(repo: Path, path: str) -> bool:
    return run_git(repo, ["cat-file", "-e", f"HEAD:{path}"], check=False).returncode == 0


def is_secret_like(path: str) -> bool:
    lower = path.lower()
    name = Path(path).name.lower()
    if name == ".env" or name.startswith(".env."):
        return True
    if name in {"id_rsa", "id_ed25519", "known_hosts"}:
        return True
    if name.endswith((".pem", ".p12", ".pfx", ".key")):
        return True
    return any(marker in lower for marker in ("secret", "token", "credential", "private_key", "api_key"))


def build_plan(repo: Path, include_ignored: bool) -> dict[str, list[str]]:
    if has_head(repo):
        changed = git_paths(repo, ["diff", "--name-only", "-z", "HEAD", "--"])
    else:
        changed = git_paths(repo, ["diff", "--cached", "--name-only", "-z", "--"])

    tracked_restore = [path for path in changed if path_in_head(repo, path)]
    tracked_remove = [path for path in changed if path not in tracked_restore]
    untracked_delete = git_paths(repo, ["ls-files", "--others", "--exclude-standard", "-z"])
    ignored = git_paths(repo, ["ls-files", "--others", "-i", "--exclude-standard", "-z"])
    ignored_secret = [path for path in ignored if is_secret_like(path)]
    ignored_non_secret = [path for path in ignored if path not in ignored_secret]

    return {
        "tracked_restore": tracked_restore,
        "tracked_remove": tracked_remove,
        "untracked_delete": untracked_delete,
        "ignored_delete": ignored_non_secret if include_ignored else [],
        "ignored_secret": ignored_secret if include_ignored else [],
        "ignored_skipped": ignored if not include_ignored else [],
    }


def section(title: str, paths: list[str]) -> None:
    print(f"{title}:")
    if not paths:
        print("  (none)")
        return
    for path in paths:
        print(f"  {path}")


def print_plan(repo: Path, plan: dict[str, list[str]], include_ignored: bool) -> None:
    print("VibeGuard authorized discard plan")
    print(f"Repository: {repo}")
    section("Tracked paths to restore from HEAD", plan["tracked_restore"])
    section("Tracked paths added to the index to remove", plan["tracked_remove"])
    section("Untracked paths to delete", plan["untracked_delete"])
    if include_ignored:
        section("Ignored paths to delete", plan["ignored_delete"])
        section("Ignored secret-like paths requiring separate confirmation", plan["ignored_secret"])
    else:
        section("Ignored paths not touched", plan["ignored_skipped"])
    print("No changes have been made by this plan output.")


def confirmed(value: str | None, env_name: str, phrase: str, token: str) -> bool:
    env_value = os.environ.get(env_name)
    return value in {phrase, token} or env_value in {phrase, token}


def total_selected(plan: dict[str, list[str]]) -> int:
    keys = ["tracked_restore", "tracked_remove", "untracked_delete", "ignored_delete", "ignored_secret"]
    return sum(len(plan[key]) for key in keys)


def checked_target(repo: Path, path: str) -> Path:
    target = repo / path
    resolved_repo = repo.resolve()
    resolved_target = target.resolve(strict=False)
    try:
        resolved_target.relative_to(resolved_repo)
    except ValueError as exc:
        raise RuntimeError(f"refusing path outside repository: {path}") from exc
    return target


def remove_path(repo: Path, path: str) -> None:
    target = checked_target(repo, path)
    if not target.exists() and not target.is_symlink():
        return
    if target.is_dir() and not target.is_symlink():
        shutil.rmtree(target)
    else:
        target.unlink()

    parent = target.parent
    while parent != repo and parent.exists():
        try:
            parent.rmdir()
        except OSError:
            break
        parent = parent.parent


def apply_plan(repo: Path, plan: dict[str, list[str]]) -> None:
    for path in plan["tracked_restore"]:
        run_git(repo, ["restore", "--staged", "--worktree", "--source=HEAD", "--", path])
    for path in plan["tracked_remove"]:
        run_git(repo, ["rm", "--cached", "-r", "--ignore-unmatch", "--", path])
        remove_path(repo, path)
    for path in plan["untracked_delete"] + plan["ignored_delete"] + plan["ignored_secret"]:
        remove_path(repo, path)


def log_file(repo: Path) -> Path:
    explicit = os.environ.get("VIBEGUARD_LOG_FILE")
    if explicit:
        return Path(explicit)
    base = Path(os.environ.get("VIBEGUARD_LOG_DIR", str(Path.home() / ".vibeguard")))
    digest = hashlib.sha256(str(repo).encode("utf-8")).hexdigest()[:8]
    project_dir = base / "projects" / digest
    project_dir.mkdir(parents=True, exist_ok=True)
    mapping = project_dir / ".project-root"
    try:
        mapping.write_text(str(repo), encoding="utf-8")
    except OSError:
        pass
    return project_dir / "events.jsonl"


def append_log(repo: Path, plan: dict[str, list[str]]) -> None:
    counts = {key: len(value) for key, value in plan.items() if key != "ignored_skipped"}
    event = {
        "schema_version": 1,
        "ts": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "session": os.environ.get("VIBEGUARD_SESSION_ID", "unknown"),
        "hook": "authorized-discard",
        "tool": "Git",
        "decision": "complete",
        "reason": "authorized destructive cleanup",
        "detail": " ".join(f"{key}={value}" for key, value in sorted(counts.items())),
    }
    path = log_file(repo)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Safely discard enumerated Git changes.")
    parser.add_argument("--plan", action="store_true", help="Print the discard plan and exit.")
    parser.add_argument("--include-ignored", action="store_true", help="Also consider ignored files.")
    parser.add_argument("--confirm", help=f'Execute only when set to "{CONFIRM_PHRASE}".')
    parser.add_argument(
        "--confirm-ignored",
        help=f'Allow ignored secret-like files only when set to "{IGNORED_CONFIRM_PHRASE}".',
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        repo = repo_root()
        plan = build_plan(repo, args.include_ignored)
        print_plan(repo, plan, args.include_ignored)
        if args.plan:
            return 0
        if total_selected(plan) == 0 and not plan["ignored_secret"]:
            print("Nothing selected to discard.")
            return 0
        if plan["ignored_secret"] and not confirmed(
            args.confirm_ignored,
            "VIBEGUARD_AUTHORIZED_DISCARD_IGNORED",
            IGNORED_CONFIRM_PHRASE,
            IGNORED_CONFIRM_TOKEN,
        ):
            print(
                f'Refusing ignored secret-like paths. Re-run with --confirm-ignored "{IGNORED_CONFIRM_PHRASE}" '
                f"or VIBEGUARD_AUTHORIZED_DISCARD_IGNORED={IGNORED_CONFIRM_TOKEN}.",
                file=sys.stderr,
            )
            return 4
        if not confirmed(args.confirm, "VIBEGUARD_AUTHORIZED_DISCARD", CONFIRM_PHRASE, CONFIRM_TOKEN):
            print(
                f'Re-run with --confirm "{CONFIRM_PHRASE}" or '
                f"VIBEGUARD_AUTHORIZED_DISCARD={CONFIRM_TOKEN}.",
                file=sys.stderr,
            )
            return 3
        apply_plan(repo, plan)
        append_log(repo, plan)
        print("Authorized discard complete.")
        return 0
    except RuntimeError as exc:
        print(f"VIBEGUARD authorized discard error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
