#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MIN_PRECISION="${MIN_PRECISION:-75}"
MIN_RECALL="${MIN_RECALL:-75}"
MIN_F1="${MIN_F1:-75}"

CSV_OUTPUT="$(bash "${REPO_DIR}/tests/run_precision.sh" --all --csv)"

VG_PRECISION_CSV="${CSV_OUTPUT}" python3 - "$MIN_PRECISION" "$MIN_RECALL" "$MIN_F1" <<'PY'
from __future__ import annotations

import csv
import io
import os
import sys

min_precision = float(sys.argv[1])
min_recall = float(sys.argv[2])
min_f1 = float(sys.argv[3])

text = os.environ.get("VG_PRECISION_CSV", "").strip()
if not text:
    print("FAIL: no CSV output from tests/run_precision.sh", file=sys.stderr)
    raise SystemExit(1)

reader = csv.DictReader(io.StringIO(text))
rows = list(reader)
if not rows:
    print("FAIL: zero precision rows parsed from CSV output", file=sys.stderr)
    raise SystemExit(1)

tp = fp = fn = 0
for row in rows:
    case_type = row.get("type", "")
    detected = row.get("detected", "0")
    try:
        detected_int = int(detected)
    except ValueError:
        print(f"FAIL: invalid detected value {detected!r}", file=sys.stderr)
        raise SystemExit(1)
    if case_type == "tp":
        if detected_int:
            tp += 1
        else:
            fn += 1
    elif case_type == "fp":
        if detected_int:
            fp += 1

precision = tp / (tp + fp) * 100 if (tp + fp) else 0.0
recall = tp / (tp + fn) * 100 if (tp + fn) else 0.0
f1 = 2 * precision * recall / (precision + recall) if (precision + recall) else 0.0

print(f"Precision: {precision:.1f}% (threshold {min_precision:.1f}%)")
print(f"Recall: {recall:.1f}% (threshold {min_recall:.1f}%)")
print(f"F1: {f1:.1f}% (threshold {min_f1:.1f}%)")
print(f"TP={tp} FP={fp} FN={fn} cases={len(rows)}")

if precision < min_precision or recall < min_recall or f1 < min_f1:
    raise SystemExit(1)
PY
