import { describe, expect, it } from 'vitest'
import type { ToolExecution, ToolExecutionResult } from '@deepseek-ai/dsh-tools'
import { VerificationTracker, toolHookPlan } from '../src/index.js'

const success = { isError: false, value: {}, content: [] } satisfies ToolExecutionResult
const signal = new AbortController().signal

function execution(name: string, argumentsValue: unknown, agent: object): ToolExecution {
  return {
    name,
    arguments: argumentsValue,
    agent,
    signal,
  } as unknown as ToolExecution
}

describe('VerificationTracker', () => {
  it('continues once after an unverified mutation', () => {
    const tracker = new VerificationTracker(new Set(['write']), [/^pnpm test$/u])
    const agent = {}
    const exec = execution('write', { file_path: 'x.ts' }, agent)
    tracker.observe(exec, toolHookPlan(exec), 4, success)

    expect(tracker.completionSignal(agent, 4)?.signal).toBe('unverified_mutation')
    expect(tracker.completionSignal(agent, 4)).toBeUndefined()
  })

  it('accepts only a successful configured verification', () => {
    const tracker = new VerificationTracker(new Set(['edit']), [/^pnpm test$/u])
    const agent = {}
    const edit = execution('edit', {}, agent)
    tracker.observe(edit, toolHookPlan(edit), 7, success)
    const bash = execution('bash', { command: 'pnpm test' }, agent)
    tracker.observe(bash, toolHookPlan(bash), 7, {
      isError: false, value: { kind: 'foreground', exitCode: 0 }, content: [],
    })

    expect(tracker.completionSignal(agent, 7)).toBeUndefined()
  })

  it('does not classify editor view as a mutation', () => {
    const tracker = new VerificationTracker(new Set(['str_replace_editor']), [/test/u])
    const agent = {}
    const view = execution('str_replace_editor', { command: 'view', path: '/x' }, agent)
    tracker.observe(view, toolHookPlan(view), 2, success)
    expect(tracker.completionSignal(agent, 2)).toBeUndefined()
  })

  it('resets state at the next turn', () => {
    const tracker = new VerificationTracker(new Set(['write']), [/test/u])
    const agent = {}
    const write = execution('write', {}, agent)
    tracker.observe(write, toolHookPlan(write), 1, success)
    expect(tracker.completionSignal(agent, 2)).toBeUndefined()
  })
})
