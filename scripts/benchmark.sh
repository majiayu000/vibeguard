#!/usr/bin/env bash
# VibeGuard Benchmark — unified scoring portal
#
# Usage:
# bash scripts/benchmark.sh --mode=fast # PR access control (Layer 1 only, zero cost)
# bash scripts/benchmark.sh --mode=standard # Daily (Layer 1 + Layer 2 critical)
# bash scripts/benchmark.sh --mode=full # Weekly (two levels of full volume)
#
# Output: VibeGuard Score + JSON result archive

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS_DIR="${VIBEGUARD_BENCHMARK_RESULTS_DIR:-$REPO_DIR/.vibeguard/benchmarks}"
DATE=$(date -u +%Y-%m-%d)
RUN_TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
COMMIT_SHA=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
RUN_ID="${RUN_TIMESTAMP}-${COMMIT_SHA}"
MODE="fast"
MODEL_BASELINE_TOOL="$REPO_DIR/eval/model_baseline.py"
L2_MODEL="$(python3 "$MODEL_BASELINE_TOOL" --print-default)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode=*) MODE="${1#--mode=}"; shift ;;
    --model=*) L2_MODEL="${1#--model=}"; shift ;;
    --help|-h)
      echo "Usage: bash scripts/benchmark.sh [--mode=fast|standard|full] [--model=ALIAS_OR_FULL_ID]"
      python3 "$MODEL_BASELINE_TOOL" --print-help-evidence
      exit 0
      ;;
    *) shift ;;
  esac
done

mkdir -p "$RESULTS_DIR"

load_layer1_csv() {
  if [[ -n "${VG_PRECISION_CSV_FILE:-}" ]]; then
    if [[ ! -f "${VG_PRECISION_CSV_FILE}" ]]; then
      echo "FAIL: VG_PRECISION_CSV_FILE does not exist: ${VG_PRECISION_CSV_FILE}" >&2
      exit 1
    fi
    cat "${VG_PRECISION_CSV_FILE}"
  elif [[ -n "${VG_PRECISION_CSV:-}" ]]; then
    printf '%s\n' "${VG_PRECISION_CSV}"
  else
    bash "$REPO_DIR/tests/run_precision.sh" --all --csv 2>/dev/null
  fi
}

echo "====== VibeGuard Benchmark ======"
echo "Date: $DATE"
echo "Run: $RUN_ID"
echo "Mode: $MODE"
echo ""

# ============================================================
# Layer 1: Hook precision (zero cost)
# ============================================================

echo "[Layer 1: Hook precision]"
L1_CSV="$(load_layer1_csv)"

# Parse CSV calculation indicators
L1_RESULT=$(echo "$L1_CSV" | python3 -c "
import sys, json

lines = [
    (lineno, line.strip())
    for lineno, line in enumerate(sys.stdin, start=1)
    if line.strip() and not line.startswith('hook,')
]
tp = fp = fn = tn = 0
by_hook = {}

for lineno, line in lines:
    parts = line.split(',')
    if len(parts) < 8:
        print(f'FAIL: malformed precision CSV line {lineno}: {line}', file=sys.stderr)
        raise SystemExit(1)
    hook, case, case_type, rule, expect, detected, passed, latency = parts
    try:
        detected = int(detected)
    except ValueError:
        print(f'FAIL: invalid detected value {detected!r} on precision CSV line {lineno}', file=sys.stderr)
        raise SystemExit(1)

    by_hook.setdefault(hook, {'tp': 0, 'fp': 0, 'fn': 0, 'tn': 0})

    if case_type == 'tp':
        if detected:
            tp += 1; by_hook[hook]['tp'] += 1
        else:
            fn += 1; by_hook[hook]['fn'] += 1
    else:
        if detected:
            fp += 1; by_hook[hook]['fp'] += 1
        else:
            tn += 1; by_hook[hook]['tn'] += 1

if not by_hook:
    print('FAIL: zero precision rows parsed from CSV output', file=sys.stderr)
    raise SystemExit(1)

precision = tp / (tp + fp) if (tp + fp) > 0 else 0
recall = tp / (tp + fn) if (tp + fn) > 0 else 0
f1 = 2 * precision * recall / (precision + recall) if (precision + recall) > 0 else 0

# Weighted F1 (all hooks have equal weight, and can be weighted according to severity in the future)
hook_f1s = []
for h, c in by_hook.items():
    p = c['tp'] / (c['tp'] + c['fp']) if (c['tp'] + c['fp']) > 0 else 0
    r = c['tp'] / (c['tp'] + c['fn']) if (c['tp'] + c['fn']) > 0 else 0
    hf1 = 2 * p * r / (p + r) if (p + r) > 0 else 0
    hook_f1s.append(hf1)

layer1_score = sum(hook_f1s) / len(hook_f1s) * 100 if hook_f1s else 0

result = {
    'tp': tp, 'fp': fp, 'fn': fn, 'tn': tn,
    'precision': round(precision * 100, 1),
    'recall': round(recall * 100, 1),
    'f1': round(f1 * 100, 1),
    'layer1_score': round(layer1_score, 1),
    'by_hook': {h: c for h, c in sorted(by_hook.items())},
    'total_cases': tp + fp + fn + tn,
}
print(json.dumps(result))
")

L1_SCORE=$(echo "$L1_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['layer1_score'])")
L1_PREC=$(echo "$L1_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['precision'])")
L1_REC=$(echo "$L1_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['recall'])")
L1_CASES=$(echo "$L1_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_cases'])")

echo "  Cases: $L1_CASES  Precision: ${L1_PREC}%  Recall: ${L1_REC}%"
echo "  Layer1_Score: $L1_SCORE"
echo ""

# ============================================================
# Layer 2: Rule compliance (requires API)
# ============================================================

L2_RESULT='{"layer2_score": 0, "sws": 0, "fpr": 0, "detection_rate": 0, "total_samples": 0}'

if [[ "$MODE" == "standard" ]] || [[ "$MODE" == "full" ]]; then
  echo "[Layer 2: Rule compliance (model=$L2_MODEL)]"
  python3 "$MODEL_BASELINE_TOOL" --describe "$L2_MODEL"

  L2_RULES_ARGS=()
  if [[ "$MODE" == "standard" ]]; then
    L2_RULES_ARGS=(--rules SEC)
  fi

  # Run LLM-as-Judge evaluation
  L2_OUTPUT=$(cd "$REPO_DIR" && python3 eval/run_eval.py --model "$L2_MODEL" "${L2_RULES_ARGS[@]}" 2>&1)
  L2_RESULT_PATH=$(printf '%s\n' "$L2_OUTPUT" | awk -F'Result saved: ' '/Result saved:/ {print $2}' | tail -1)

  # Read the immutable eval run artifact emitted by run_eval.py.
  if [[ -n "$L2_RESULT_PATH" ]] && [[ -f "$L2_RESULT_PATH" ]]; then
    L2_RESULT=$(python3 -c "
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

results = data.get('results', [])
tp_results = [r for r in results if 'detected' in r]
fp_results = [r for r in results if 'detected_fp' in r]

detected = sum(1 for r in tp_results if r['detected'])
total_tp = len(tp_results)
dr = detected / total_tp if total_tp else 0

fp_count = sum(1 for r in fp_results if r['detected_fp'])
fpr = fp_count / len(fp_results) if fp_results else 0

sev_w = {'critical': 4, 'high': 3, 'medium': 2, 'low': 1}
w_sum = sum(sev_w.get(r.get('severity','medium'), 2) for r in tp_results if r['detected'])
w_total = sum(sev_w.get(r.get('severity','medium'), 2) for r in tp_results)
sws = w_sum / w_total * 100 if w_total else 0

fpr_penalty = max(0, 1 - fpr)
layer2_score = sws * fpr_penalty

print(json.dumps({
    'layer2_score': round(layer2_score, 1),
    'sws': round(sws, 1),
    'fpr': round(fpr * 100, 1),
    'detection_rate': round(dr * 100, 1),
    'total_samples': len(results),
}))
" "$L2_RESULT_PATH")

    L2_SCORE=$(echo "$L2_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['layer2_score'])")
    L2_DR=$(echo "$L2_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['detection_rate'])")
    L2_FPR=$(echo "$L2_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['fpr'])")
    L2_SAMPLES=$(echo "$L2_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_samples'])")

    echo "  Samples: $L2_SAMPLES  DR: ${L2_DR}%  FPR: ${L2_FPR}%"
    echo "  Layer2_Score: $L2_SCORE"
  else
    echo "[Skip] eval immutable results artifact not generated"
  fi
  echo ""
fi

# ============================================================
# VibeGuard Score calculation
# ============================================================

SCORE_RESULT=$(python3 -c "
import json

l1 = json.loads('$L1_RESULT')
l2 = json.loads('$L2_RESULT')

l1_score = l1['layer1_score']
l2_score = l2['layer2_score']

if l2_score > 0:
    score = 0.4 * l1_score + 0.6 * l2_score
else:
    score = l1_score  # fast mode: Layer 1 only

if score >= 90: grade = 'A'
elif score >= 75: grade = 'B'
elif score >= 60: grade = 'C'
else: grade = 'D'

print(json.dumps({
    'score': round(score, 1),
    'grade': grade,
    'layer1_score': l1_score,
    'layer2_score': l2_score,
}))
")

SCORE=$(echo "$SCORE_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['score'])")
GRADE=$(echo "$SCORE_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['grade'])")

echo "[VibeGuard Score] $SCORE → $GRADE"

# ============================================================
# Delta comparison
# ============================================================

PREV_FILE=$(find "$RESULTS_DIR" -maxdepth 1 -type f -name '*T*.json' -print 2>/dev/null | sort | tail -1 || true)
if [[ -n "$PREV_FILE" ]] && [[ -f "$PREV_FILE" ]]; then
  PREV_SCORE=$(python3 -c "import json; print(json.load(open('$PREV_FILE'))['score'])" 2>/dev/null || echo "0")
  DELTA=$(python3 -c "print(f'{$SCORE - $PREV_SCORE:+.1f}')")
  PREV_DATE=$(basename "$PREV_FILE" .json)
  echo "[Trend] Last time ($PREV_DATE): $PREV_SCORE → This time: $SCORE ($DELTA)"
fi

# ============================================================
# Archive
# ============================================================

OUTPUT_FILE="$RESULTS_DIR/$RUN_ID.json"
python3 -c "
import json
result = {
    'run_id': '$RUN_ID',
    'date': '$DATE',
    'created_at': '$RUN_TIMESTAMP',
    'commit': '$COMMIT_SHA',
    'mode': '$MODE',
    'score': $SCORE,
    'grade': '$GRADE',
    'layer1': json.loads('$L1_RESULT'),
    'layer2': json.loads('$L2_RESULT'),
}
with open('$OUTPUT_FILE', 'w') as f:
    json.dump(result, f, indent=2, ensure_ascii=False)
"

echo ""
echo "Results archived: $OUTPUT_FILE"
echo "=============================="
