import { describe, expect, it } from 'vitest'
import {
  HOOK_IDS,
  guardDecision,
  interpretHookResult,
  mergeDecisions,
  serializeDecision,
  type HookId,
  type HookRunResult,
} from '../src/index.js'

const clean: HookRunResult = {
  exitCode: 0,
  signal: null,
  timedOut: false,
  aborted: false,
  stdout: '',
  stderr: '',
}

function output(stdout: unknown): HookRunResult {
  return { ...clean, stdout: JSON.stringify(stdout) }
}

describe.each(HOOK_IDS)('%s decision contract', (hook: HookId) => {
  it('allows empty successful output', () => {
    expect(interpretHookResult(hook, clean, 'closed')).toEqual(guardDecision('allow'))
  })

  it('surfaces advisory context as a typed warning', () => {
    const decision = interpretHookResult(hook, output({
      hookSpecificOutput: { additionalContext: 'check this', hookEventName: 'PostToolUse' },
    }), 'closed')
    expect(decision.decision).toBe('warn')
    expect(decision.signals).toEqual([expect.objectContaining({ reason: 'check this' })])
  })

  it('turns a canonical block into a denial', () => {
    const decision = interpretHookResult(hook, output({ decision: 'block', reason: 'blocked' }), 'closed')
    expect(decision.decision).toBe('deny')
    expect(decision.signals[0]?.reason).toBe('blocked')
  })

  it('fails closed with orthogonal process facts', () => {
    const decision = interpretHookResult(hook, {
      ...clean,
      exitCode: null,
      signal: 'SIGTERM',
      timedOut: true,
      stderr: 'killed',
      stdoutTruncated: true,
    }, 'closed')
    expect(decision.decision).toBe('deny')
    expect(decision.signals[0]?.signal_type).toBe('guard_error')
    expect(decision.signals[0]?.reason).toContain('signal=SIGTERM')
    expect(decision.signals[0]?.reason).toContain('timed_out=true')
    expect(decision.signals[0]?.reason).toContain('stdout_truncated=true')
  })
})

describe('decision composition', () => {
  it('retains an open-mode infrastructure warning', () => {
    const decision = interpretHookResult('pre-bash-guard', { ...clean, exitCode: 1 }, 'open')
    expect(decision.decision).toBe('warn')
    expect(decision.signals[0]?.signal_type).toBe('guard_error')
  })

  it('treats strict constraint exit 2 as a policy denial', () => {
    const decision = interpretHookResult('count-active-constraints', {
      ...clean, exitCode: 2, stderr: '[BLOCKED] too many constraints',
    }, 'open')
    expect(decision.decision).toBe('deny')
    expect(decision.signals[0]?.signal_type).toBe('constraints')
  })

  it('accepts the stop guard plain-text advisory as a warning', () => {
    const decision = interpretHookResult('stop-guard', {
      ...clean,
      stdout: 'VIBEGUARD [W-16] run a focused test before finishing',
    }, 'closed')
    expect(decision).toEqual(guardDecision('warn', [{
      signal_type: 'completion',
      signal: 'stop_guard',
      reason: 'VIBEGUARD [W-16] run a focused test before finishing',
    }]))
  })

  it('merges severity and serializes required signals', () => {
    const merged = mergeDecisions([
      guardDecision('warn', [{ signal_type: 'quality', signal: 'quality', reason: 'warn' }]),
      guardDecision('continue', [{ signal_type: 'completion', signal: 'verify', reason: 'verify' }]),
    ])
    expect(merged.decision).toBe('continue')
    expect(JSON.parse(serializeDecision(merged))).toEqual(merged)
  })
})
