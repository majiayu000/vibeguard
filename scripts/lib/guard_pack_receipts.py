#!/usr/bin/env python3
"""Receipt helpers for Guard Pack registration."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from file_ops import write_json_atomic


class ReceiptError(ValueError):
    """User-facing receipt error."""


def receipt_path_for_pack(pack_id: str, target_id: str) -> str:
    return f"~/.vibeguard/guard-packs/{pack_id}/{target_id}/receipt.json"


def receipt_file_for_pack(pack_id: str, target_id: str, home: Path) -> Path:
    return home / ".vibeguard" / "guard-packs" / pack_id / target_id / "receipt.json"


def build_receipt(
    pack: dict[str, Any],
    target_id: str,
    profile: str,
    target: dict[str, Any],
    *,
    dry_run: bool = True,
    audit: dict[str, Any] | None = None,
) -> dict[str, Any]:
    receipt_path = receipt_path_for_pack(str(pack["id"]), target_id)
    audit_checks = target.get("audit_checks", [])
    audit_check_ids = [
        str(check["id"])
        for check in audit_checks
        if isinstance(check, dict) and isinstance(check.get("id"), str)
    ]
    receipt = {
        "schema_version": 1,
        "type": "guard_pack_install_receipt_preview" if dry_run else "guard_pack_install_receipt",
        "dry_run": dry_run,
        "writes": 0 if dry_run else 1,
        "receipt_path": receipt_path,
        "pack": {
            "id": pack["id"],
            "version": pack["version"],
            "status": pack["status"],
        },
        "target": target_id,
        "profile": profile,
        "adoption_layer_only": pack["adoption_layer_only"],
        "source_of_truth": pack["source_of_truth"],
        "plan": {
            "would_install": target.get("would_install", []),
            "would_modify": target.get("would_modify", []),
            "would_enable_surfaces": target.get("surfaces", []),
            "limitations": target.get("limitations", []),
        },
        "rollback_plan": [
            "Dry-run writes no files, so no rollback is required."
            if dry_run
            else f"Remove only this receipt file: {receipt_path}.",
            f"Future selective installs must remove only files recorded in {receipt_path}.",
            "Future config rollback must remove only this pack's managed hook entries and preserve unrelated user hooks.",
        ],
        "audit": {
            "command": f"bash setup.sh packs audit {pack['id']} --target {target_id}",
            "check_ids": audit_check_ids,
        },
    }
    if not dry_run:
        receipt["actual_writes"] = [receipt_path]
        receipt["audit_snapshot"] = audit
    return receipt


def write_install_receipt(path: Path, receipt: dict[str, Any]) -> None:
    try:
        write_json_atomic(path, receipt)
    except OSError as exc:
        raise ReceiptError(f"cannot write install receipt {path}: {exc}") from exc


def remove_install_receipt(path: Path) -> None:
    try:
        path.unlink()
    except OSError as exc:
        raise ReceiptError(f"cannot remove install receipt {path}: {exc}") from exc


def assert_receipt_path_safe(path: Path, home: Path) -> None:
    root = (home / ".vibeguard" / "guard-packs").resolve(strict=False)
    actual = path.resolve(strict=False)
    try:
        actual.relative_to(root)
    except ValueError as exc:
        raise ReceiptError(f"refusing to remove receipt outside {root}: {actual}") from exc


def load_install_receipt(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ReceiptError(f"cannot read install receipt {path}: missing") from exc
    except UnicodeDecodeError as exc:
        raise ReceiptError(f"cannot read install receipt {path}: invalid UTF-8") from exc
    except json.JSONDecodeError as exc:
        raise ReceiptError(f"cannot read install receipt {path}: invalid JSON: {exc.msg}") from exc
    if not isinstance(data, dict):
        raise ReceiptError(f"cannot read install receipt {path}: JSON root is not an object")
    return data


def validate_install_receipt(
    receipt: dict[str, Any],
    pack: dict[str, Any],
    target_id: str,
) -> None:
    pack_meta = receipt.get("pack")
    expected_path = receipt_path_for_pack(str(pack["id"]), target_id)
    actual_writes = receipt.get("actual_writes")
    if receipt.get("type") != "guard_pack_install_receipt" or receipt.get("dry_run") is not False:
        raise ReceiptError("refusing to remove a file that is not an installed guard pack receipt")
    if not isinstance(pack_meta, dict) or pack_meta.get("id") != pack["id"]:
        raise ReceiptError("receipt pack id does not match uninstall request")
    if receipt.get("target") != target_id:
        raise ReceiptError("receipt target does not match uninstall request")
    if receipt.get("receipt_path") != expected_path:
        raise ReceiptError("receipt path does not match pack-managed receipt path")
    if not isinstance(actual_writes, list) or expected_path not in actual_writes:
        raise ReceiptError("receipt does not record its own file in actual_writes")
