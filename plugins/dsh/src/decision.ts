/** Hook output parsing and stable decision composition. */

import type {
  GuardDecision,
  GuardSignal,
  HookId,
  HookRunResult,
  SignalType,
} from './types.js'

const SIGNAL_TYPES: Record<HookId, SignalType> = {
  'count-active-constraints': 'constraints',
  'pre-bash-guard': 'command_policy',
  'pre-edit-guard': 'file_policy',
  'pre-write-guard': 'file_policy',
  'post-edit-guard': 'quality',
  'post-write-guard': 'quality',
  'post-build-check': 'build',
  'analysis-paralysis-guard': 'analysis',
  'stop-guard': 'completion',
  'learn-evaluator': 'learning',
}

/** Create a stable guard decision without undefined signal fields. */
export function guardDecision(
  decision: GuardDecision['decision'],
  signals: GuardSignal[] = [],
): GuardDecision {
  return { version: 'vibeguard.dsh/v1', decision, signals }
}

/** Serialize a decision for DSH logs and model-visible content. */
export function serializeDecision(decision: GuardDecision): string {
  return JSON.stringify(decision)
}

/** Merge hook decisions; deny wins, then continue, then warn. */
export function mergeDecisions(decisions: readonly GuardDecision[]): GuardDecision {
  const signals = decisions.flatMap(decision => decision.signals)
  if (decisions.some(decision => decision.decision === 'deny')) return guardDecision('deny', signals)
  if (decisions.some(decision => decision.decision === 'continue')) return guardDecision('continue', signals)
  if (decisions.some(decision => decision.decision === 'warn')) return guardDecision('warn', signals)
  return guardDecision('allow', signals)
}

function record(value: unknown): Record<string, unknown> | undefined {
  return typeof value === 'object' && value !== null ? value as Record<string, unknown> : undefined
}

function text(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined
}

function signalFor(hook: HookId, reason: string, type = SIGNAL_TYPES[hook]): GuardSignal {
  return { signal_type: type, signal: hook.replaceAll('-', '_'), reason }
}

function processFacts(result: HookRunResult): string {
  return [
    `exit_code=${String(result.exitCode)}`,
    `signal=${String(result.signal)}`,
    `timed_out=${String(result.timedOut)}`,
    `aborted=${String(result.aborted)}`,
    `stdout_truncated=${String(result.stdoutTruncated === true)}`,
    text(result.stderr) === undefined ? '' : `stderr=${text(result.stderr)}`,
  ].filter(Boolean).join(', ')
}

function abnormal(result: HookRunResult): boolean {
  return result.exitCode !== 0 || result.signal !== null || result.timedOut
    || result.aborted || result.stdoutTruncated === true
}

/** Convert one canonical VibeGuard hook outcome into the DSH decision contract. */
export function interpretHookResult(
  hook: HookId,
  result: HookRunResult,
  failureMode: 'closed' | 'open',
): GuardDecision {
  if (abnormal(result)) {
    const reason = `VibeGuard hook did not complete cleanly: ${processFacts(result)}`
    const policyBlock = hook === 'count-active-constraints' && result.exitCode === 2
    const signal = policyBlock
      ? signalFor(hook, text(result.stderr) ?? reason)
      : signalFor(hook, reason, 'guard_error')
    return guardDecision(policyBlock || failureMode === 'closed' ? 'deny' : 'warn', [signal])
  }

  const output = result.stdout.trim()
  if (output === '') {
    const stderr = text(result.stderr)
    return stderr === undefined
      ? guardDecision('allow')
      : guardDecision('warn', [signalFor(hook, stderr, 'guard_error')])
  }

  let parsed: Record<string, unknown>
  try {
    parsed = record(JSON.parse(output)) ?? {}
  } catch (error: unknown) {
    if (hook === 'stop-guard') {
      return guardDecision('warn', [signalFor(hook, output)])
    }
    const reason = `VibeGuard hook emitted invalid JSON: ${error instanceof Error ? error.message : String(error)}`
    return guardDecision(failureMode === 'closed' ? 'deny' : 'warn', [signalFor(hook, reason, 'guard_error')])
  }

  const specific = record(parsed.hookSpecificOutput)
  const denied = parsed.decision === 'block' || specific?.permissionDecision === 'deny'
  const reasons = [
    text(parsed.reason),
    text(specific?.permissionDecisionReason),
    text(specific?.additionalContext),
    text(parsed.stopReason),
    text(parsed.systemMessage),
  ].filter((value): value is string => value !== undefined)
  if (denied) {
    return guardDecision('deny', [signalFor(hook, reasons[0] ?? `Blocked by ${hook}.`)])
  }
  if (reasons.length > 0) {
    return guardDecision('warn', reasons.map(reason => signalFor(hook, reason)))
  }
  return guardDecision('allow')
}
