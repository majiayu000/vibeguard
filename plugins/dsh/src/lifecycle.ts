/** Per-agent state for startup delivery, verification, and stop-loop control. */

import type { Agent } from '@deepseek-ai/dsh-agent'
import type { ToolExecution, ToolExecutionResult } from '@deepseek-ai/dsh-tools'
import type { GuardDecision, GuardSignal } from './types.js'
import type { ToolHookPlan } from './payloads.js'

interface TurnState {
  dirty: boolean
  steered: boolean
  turn: number
  verified: boolean
}

function commandOf(value: unknown): string {
  if (typeof value !== 'object' || value === null || !('command' in value)) return ''
  return typeof value.command === 'string' ? value.command : ''
}

function successful(result: Readonly<ToolExecutionResult>): boolean {
  if (result.isError) return false
  if (typeof result.value !== 'object' || result.value === null || !('exitCode' in result.value)) return true
  return result.value.exitCode === 0
}

/** Track mutations and successful verification commands per DSH turn. */
export class VerificationTracker {
  private readonly states = new WeakMap<object, TurnState>()

  constructor(
    private readonly mutatingTools: ReadonlySet<string>,
    private readonly verificationPatterns: readonly RegExp[],
  ) {}

  /** Observe one settled call without treating editor view operations as mutations. */
  observe(
    exec: Readonly<ToolExecution>,
    plan: ToolHookPlan,
    turn: number,
    result: Readonly<ToolExecutionResult>,
  ): void {
    if (!exec.agent) return
    let state = this.states.get(exec.agent)
    if (state === undefined || state.turn !== turn) {
      state = { dirty: false, steered: false, turn, verified: false }
      this.states.set(exec.agent, state)
    }
    if (!successful(result)) return
    const mutation = this.mutatingTools.has(exec.name)
      && (exec.name !== 'str_replace_editor' || plan.mutation)
    if (mutation) {
      state.dirty = true
      state.verified = false
      return
    }
    const command = commandOf(exec.arguments)
    if (exec.name === 'bash' && state.dirty
      && this.verificationPatterns.some(pattern => pattern.test(command))) {
      state.verified = true
    }
  }

  /** Return the continuation signal at most once for one dirty, unverified turn. */
  completionSignal(agent: object, turn: number): GuardSignal | undefined {
    const state = this.states.get(agent)
    if (state === undefined || state.turn !== turn || !state.dirty || state.verified || state.steered) return undefined
    state.steered = true
    return {
      signal_type: 'completion',
      signal: 'unverified_mutation',
      reason: 'Files changed in this turn, but no configured verification command completed successfully. Run a focused test, check, lint, or build before finishing.',
    }
  }
}

/** Gate first-step delivery on an asynchronously executed SessionStart hook. */
export class StartupGate {
  private readonly controller = new AbortController()
  private readonly pending = new Set<Promise<GuardDecision>>()
  private readonly byAgent = new WeakMap<Agent, Promise<GuardDecision>>()

  /** Start one hook run at the emit-shaped session boundary. */
  start(agent: Agent, task: (signal: AbortSignal) => Promise<GuardDecision>): void {
    const promise = task(this.controller.signal)
    this.byAgent.set(agent, promise)
    this.pending.add(promise)
    void promise.then(
      () => this.pending.delete(promise),
      () => this.pending.delete(promise),
    )
  }

  /** Await and consume the pending SessionStart decision for one agent. */
  async take(agent: Agent): Promise<GuardDecision | undefined> {
    const promise = this.byAgent.get(agent)
    if (promise === undefined) return undefined
    this.byAgent.delete(agent)
    return promise
  }

  /** Abort detached work and wait until every spawned hook reaches quiescence. */
  async dispose(): Promise<void> {
    this.controller.abort()
    await Promise.allSettled(this.pending)
  }
}

/** Ensure Stop and learning hooks execute once per DSH turn. */
export class StopTracker {
  private readonly turns = new WeakMap<Agent, number>()

  /** Return true on the first stop boundary observed for this agent/turn. */
  first(agent: Agent, turn: number): boolean {
    if (this.turns.get(agent) === turn) return false
    this.turns.set(agent, turn)
    return true
  }
}
