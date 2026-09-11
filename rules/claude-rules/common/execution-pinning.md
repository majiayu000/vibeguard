# Execution Pinning Rules

## W-20: Pin execution surfaces for explicitly reproducible experiments (guideline)
Capture runtime, tool, and rule versions when the user or project requires a reproducible experiment or controlled comparison. Task duration, step count, delegation, and cross-session planning alone do not require snapshots.

For such an experiment, use the existing `guards/universal/check_runtime_drift.sh` with the relevant tool inventory and installed rules. Store snapshots outside the target repository under `${VIBEGUARD_HOME:-${HOME}/.vibeguard}/artifacts/runtime-pinning/<project-name>/`, using task-specific names. Record the paths in the experiment's existing notes.

On resume, compare the surfaces needed for the experiment before claiming comparable results. Report meaningful drift and either restore the experiment conditions or rerun the affected checks. Do not require an unrelated security log or a complete inventory of unused tools.

**FIX / SKIP**: Fix unsupported reproducibility claims. Skip snapshots for ordinary implementation, analysis, ExecPlan creation, and status reads. Fresh verification remains required by W-03/W-16.
