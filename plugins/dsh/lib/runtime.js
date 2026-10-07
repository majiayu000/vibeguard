function quote(value) { return `'${value.replaceAll("'", "'\\''")}'`; }
export async function runHook(ctx, options, payload, signal) {
    try {
        const execution = await ctx.shell.execute(ctx.shell.resolve({
            command: `${quote(options.runtimePath)} hook dsh --state-dir ${quote(options.stateDir)}`,
            workdir: String(payload.cwd),
            stdin: JSON.stringify(payload),
            timeoutMs: options.timeoutMs,
            stdoutMaxBytes: 65536,
            signal,
        }));
        const result = await execution.result();
        if (result.exitCode !== 0 || result.signal || result.timedOut || result.aborted || result.stdout.truncated) {
            return { kind: 'error', reason: `VibeGuard runtime failed (exit=${String(result.exitCode)}, signal=${String(result.signal)}, timeout=${result.timedOut}, aborted=${result.aborted}, truncated=${result.stdout.truncated}). Check the runtime installation; this call requires a working guard.` };
        }
        if (result.stdout.text.trim() === '')
            return { kind: 'allow' };
        const parsed = JSON.parse(result.stdout.text);
        if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed))
            throw new Error('invalid runtime response');
        if (parsed.hookSpecificOutput?.permissionDecision === 'deny') {
            return { kind: 'policy', reason: parsed.hookSpecificOutput.permissionDecisionReason || 'VibeGuard denied this command; explicit approval is required.' };
        }
        return { kind: 'allow', reason: parsed.systemMessage };
    }
    catch {
        // Do not echo payloads, shell stderr or exception strings into host logs.
        return { kind: 'error', reason: 'VibeGuard runtime could not complete or returned invalid JSON. Check the runtime installation; this call requires a working guard.' };
    }
}
