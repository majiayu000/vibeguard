import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import LlmRuntime, { ToolCallId, createUserMessage, LlmAdapter, type GenerateOptions, type StreamChunk } from '@deepseek-ai/dsh-llm'
import SessionStore, { SessionId, type SessionEvent } from '@deepseek-ai/dsh-session'
import SessionProjectionRegistry from '@deepseek-ai/dsh-session-projection'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime, { defineTool } from '@deepseek-ai/dsh-tools'
import AgentRegistry from '@deepseek-ai/dsh-agent'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import ApprovalService, { type ApprovalOutcome } from '@deepseek-ai/dsh-user-approval'
import LocalSubprocessRuntime from '@deepseek-ai/dsh-subprocess-local'
import LocalBashExecutor from '@deepseek-ai/dsh-bash-local'
import * as ShellEnv from '@deepseek-ai/dsh-shell-env'
import * as VibeGuard from '../src/index.js'

const runtimePath = resolve('../../vibeguard-runtime/target/debug/vibeguard-runtime')
const dirs: string[] = []
const contexts: Context[] = []
afterEach(async () => {
  for (const ctx of contexts.splice(0)) await ctx.fiber.dispose()
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
})
function temp() { const dir = mkdtempSync(join(tmpdir(), 'vibeguard-dsh-')); dirs.push(dir); return dir }

class OfflineModel extends LlmAdapter {
  private responses = 0
  async *stream(_options: GenerateOptions): AsyncIterable<StreamChunk> {
    const first = this.responses++ === 0
    const block = first
      ? { type: 'tool-call' as const, id: ToolCallId('model-bash'), name: 'bash', arguments: JSON.stringify({ command: 'git clean -fd' }) }
      : { type: 'text' as const, text: 'finished' }
    yield { type: 'block-start', index: 0, blockType: block.type }
    yield { type: 'block-end', index: 0, block }
    yield { type: 'finish', reason: { kind: first ? 'tool-calls' : 'stop' } }
  }
}

async function setup(options: { approval?: boolean; runtime?: string; timeoutMs?: number; stateDir?: string } = {}) {
  const ctx = new Context(); contexts.push(ctx)
  const stateDir = options.stateDir ?? temp()
  const events: SessionEvent[] = []
  ctx.on('session/event', (_session, event) => { events.push(event) })
  await ctx.plugin(LlmRuntime)
  await ctx.plugin(SessionStore)
  await ctx.plugin(SessionProjectionRegistry)
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(AgentRegistry)
  await ctx.plugin(AgentLoop, { agents: [] })
  await ctx.plugin(LocalSubprocessRuntime)
  await ctx.plugin(ShellEnv)
  await ctx.plugin(LocalBashExecutor, { graceMs: 50 })
  if (options.approval !== false) await ctx.plugin(ApprovalService)
  await ctx.plugin(VibeGuard, { runtimePath: options.runtime ?? runtimePath, stateDir, timeoutMs: options.timeoutMs ?? 5000 })
  let dispatched = 0
  let value: Record<string, string | number | boolean> = { kind: 'foreground', exitCode: 0 }
  ctx.tools.register(defineTool({
    name: 'bash', description: 'INERT test tool: never executes arguments',
    parameters: { command: { type: 'string', required: true } },
    output: { schema: { type: 'object', additionalProperties: true }, render: () => [{ type: 'text', text: 'inert result' }] },
    async execute() { dispatched++; return value },
  }))
  ctx.llm.registerAdapter(['offline'], new OfflineModel())
  const agent = await ctx.agentLoop.create(SessionId('test-agent'), { provider: 'offline', model: 'offline' }, { cwd: stateDir })
  return { ctx, agent, stateDir, events, dispatched: () => dispatched, setValue: (v: Record<string, string | number | boolean>) => { value = v } }
}
function openTurn(h: Awaited<ReturnType<typeof setup>>) { h.agent.session.append('turn/start', { turn: 1 }) }
function call(h: Awaited<ReturnType<typeof setup>>, command: string, signal = new AbortController().signal, agent = h.agent) {
  return h.ctx.tools.execute({ name: 'bash', callId: ToolCallId('probe'), arguments: { command }, agent, signal })
}

// Real Rust receives these strings on stdin. The inert tool never evaluates them.
describe('real DSH native approval and Rust command guard', () => {
  it.each(['allowed-once', 'rejected', 'cancelled', 'unavailable'] as ApprovalOutcome[])('%s routes through native approval and audit', async outcome => {
    const h = await setup(); openTurn(h)
    h.ctx.on('approval/request', () => Promise.resolve(outcome))
    const result = await call(h, 'rm -rf /')
    expect(result.isError).toBe(outcome !== 'allowed-once')
    expect(h.dispatched()).toBe(outcome === 'allowed-once' ? 1 : 0)
    const audit = h.events.filter(e => e.type.startsWith('approval/'))
    expect(audit.map(e => e.type)).toEqual(['approval/asked', 'approval/decided'])
    expect(audit[1]?.data).toMatchObject({ outcome })
  })

  it.each([true, false])('fails closed without an approval answer (service=%s)', async approval => {
    const h = await setup({ approval }); openTurn(h)
    expect((await call(h, 'git clean -fd')).isError).toBe(true)
    expect(h.dispatched()).toBe(0)
  })

  it('fails closed with no agent and no approval route', async () => {
    const h = await setup()
    const result = await h.ctx.tools.execute({ name: 'bash', callId: ToolCallId('unowned'), arguments: { command: 'git clean -fd' }, signal: new AbortController().signal })
    expect(result.isError).toBe(true); expect(h.dispatched()).toBe(0)
  })

  it('caller cancellation during approval cannot dispatch after a grant', async () => {
    const h = await setup(); openTurn(h)
    const entered = Promise.withResolvers<void>(); const release = Promise.withResolvers<ApprovalOutcome>()
    h.ctx.on('approval/request', () => { entered.resolve(); return release.promise })
    const controller = new AbortController()
    const pending = call(h, 'git clean -fd', controller.signal)
    await entered.promise; controller.abort(); release.resolve('allowed-once')
    expect((await pending).isError).toBe(true); expect(h.dispatched()).toBe(0)
  })

  it('preserves another downstream policy denial', async () => {
    const h = await setup(); openTurn(h)
    h.ctx.on('tools/pre-execute', async () => ({ kind: 'deny', reason: 'another policy' }))
    let asked = 0; h.ctx.on('approval/request', () => { asked++; return Promise.resolve('allowed-once') })
    expect((await call(h, 'git clean -fd')).isError).toBe(true)
    expect(asked).toBe(0); expect(h.dispatched()).toBe(0)
  })

  it('records structured result facts under the DSH host', async () => {
    const h = await setup()
    expect((await call(h, 'printf harmless')).isError).toBe(false)
    expect(JSON.parse(readFileSync(join(h.stateDir, 'dsh.json'), 'utf8'))).toMatchObject({ host: 'dsh', event: 'PostToolUse', outcome: 'exited_zero', exit_code: 0 })
    h.setValue({ kind: 'foreground', stdout: 'all tests passed' })
    await call(h, 'printf harmless')
    const observation = readFileSync(join(h.stateDir, 'dsh.json'), 'utf8')
    expect(JSON.parse(observation).outcome).toBe('exit_status_unavailable')
    expect(observation).not.toContain('all tests passed'); expect(observation).not.toContain('printf harmless')
    h.setValue({ kind: 'background', jobId: 'job-1' }); await call(h, 'printf harmless')
    expect(JSON.parse(readFileSync(join(h.stateDir, 'dsh.json'), 'utf8')).outcome).toBe('running')
  })

  it.each(['exit 2', "printf 'not-json'", 'sleep 1'])('runtime failure %s is hard denied without asking', async script => {
    const dir = temp(); const runtime = join(dir, 'guard'); writeFileSync(runtime, '#!/bin/sh\n' + script + '\n', { mode: 0o700 })
    const h = await setup({ runtime, timeoutMs: 100 }); openTurn(h)
    let asked = 0; h.ctx.on('approval/request', () => { asked++; return Promise.resolve('allowed-once') })
    expect((await call(h, 'printf harmless')).isError).toBe(true)
    expect(asked).toBe(0); expect(h.dispatched()).toBe(0)
  })

  it('post-call protocol failure preserves completed result and surfaces a notice', async () => {
    const h = await setup(); h.setValue({ exitCode: 'not-an-integer' })
    const result = await call(h, 'printf harmless')
    expect(result.isError).toBe(false); expect(h.dispatched()).toBe(1)
    expect(result.additionalContexts?.[0]?.source).toMatchObject({ kind: 'vibeguard', form: 'notice' })
  })

  it('executes a real AgentLoop turn and drains its lifecycle', async () => {
    const h = await setup()
    h.ctx.on('approval/request', () => Promise.resolve('allowed-once'))
    const idle = new Promise<void>(resolve => { const dispose = h.ctx.on('agent/status', ({ agent, status }) => { if (agent === h.agent && status === 'idle') { dispose(); resolve() } }) })
    h.agent.followup(createUserMessage({ content: [{ type: 'text', text: 'run the inert guard probe' }], source: { kind: 'user' } }))
    await idle
    expect(h.dispatched()).toBe(1)
    expect(h.events.some(e => e.type === 'turn/end')).toBe(true)
    expect(h.events.filter(e => e.type === 'approval/decided')).toHaveLength(1)
    await h.ctx.fiber.dispose()
  })
})
