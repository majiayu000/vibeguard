/** Invoke the trusted runtime; proposed commands only travel on stdin. */
import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-shell'

export interface RuntimeOptions { runtimePath: string; stateDir: string; timeoutMs: number }
export type RuntimeDecision = { kind: 'allow'; reason?: string } | { kind: 'policy' | 'error'; reason: string }

function quote(value: string): string { return `'${value.replaceAll("'", "'\\''")}'` }

export async function runHook(
  ctx: Context,
  options: RuntimeOptions,
  payload: Record<string, unknown>,
  signal: AbortSignal,
): Promise<RuntimeDecision> {
  try {
    const execution = await ctx.shell.execute(ctx.shell.resolve({
      command: `${quote(options.runtimePath)} hook dsh --state-dir ${quote(options.stateDir)}`,
      workdir: String(payload.cwd),
      stdin: JSON.stringify(payload),
      timeoutMs: options.timeoutMs,
      stdoutMaxBytes: 65536,
      signal,
    }))
    const result = await execution.result()
    if (result.exitCode !== 0 || result.signal || result.timedOut || result.aborted || result.stdout.truncated) {
      return { kind: 'error', reason: `VibeGuard runtime failed (exit=${String(result.exitCode)}, signal=${String(result.signal)}, timeout=${result.timedOut}, aborted=${result.aborted}, truncated=${result.stdout.truncated}). Check the runtime installation; this call requires a working guard.` }
    }
    if (result.stdout.text.trim() === '') return { kind: 'allow' }
    const parsed = JSON.parse(result.stdout.text) as { hookSpecificOutput?: { permissionDecision?: string; permissionDecisionReason?: string }; systemMessage?: string }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('invalid runtime response')
    if (parsed.hookSpecificOutput?.permissionDecision === 'deny') {
      return { kind: 'policy', reason: parsed.hookSpecificOutput.permissionDecisionReason || 'VibeGuard denied this command; explicit approval is required.' }
    }
    return { kind: 'allow', reason: parsed.systemMessage }
  } catch {
    // Do not echo payloads, shell stderr or exception strings into host logs.
    return { kind: 'error', reason: 'VibeGuard runtime could not complete or returned invalid JSON. Check the runtime installation; this call requires a working guard.' }
  }
}
