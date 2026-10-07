/** Thin Bash adapter for the installed VibeGuard Rust runtime. */
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createUserMessage } from '@deepseek-ai/dsh-llm';
import z from '@deepseek-ai/schemastery';
import { runHook } from './runtime.js';
export const name = 'vibeguard-dsh';
export const inject = ['shell', 'tools'];
export const Config = z.object({
    runtimePath: z.string().default(''),
    stateDir: z.string().default(''),
    timeoutMs: z.number().default(5000),
});
/** Translate structured DSH facts; display text is never an exit status. */
export function toolPayload(exec, result) {
    const value = result?.value;
    const facts = typeof value === 'object' && value !== null ? value : {};
    return {
        hook_event_name: result === undefined ? 'PreToolUse' : 'PostToolUse',
        cwd: exec.agent?.session.header.cwd ?? process.cwd(),
        tool_name: 'Bash',
        tool_input: exec.arguments,
        tool_use_id: exec.callId,
        ...(result === undefined ? {} : { tool_response: {
                isError: result.isError,
                exit_code: facts.exitCode,
                session_id: facts.kind === 'background' ? facts.jobId : undefined,
                interrupted: facts.aborted === true,
            } }),
    };
}
/** Mount native pre/post events without implementing policy in TypeScript. */
export function apply(ctx, config) {
    const runtimePath = config.runtimePath || join(homedir(), '.vibeguard', 'bin', 'vibeguard-runtime');
    if (!existsSync(runtimePath)) {
        throw new Error(`vibeguard-dsh: runtime missing at ${runtimePath}; run cargo build --locked --manifest-path vibeguard-runtime/Cargo.toml in the VibeGuard checkout, then set runtimePath to the built executable`);
    }
    const timeoutMs = config.timeoutMs ?? 5000;
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1)
        throw new Error('vibeguard-dsh: timeoutMs must be a positive integer');
    const options = { runtimePath, timeoutMs, stateDir: config.stateDir || join(homedir(), '.vibeguard', 'state') };
    ctx.on('tools/pre-execute', async (exec, next) => {
        if (exec.name !== 'bash')
            return next();
        const decision = await runHook(ctx, options, toolPayload(exec), exec.signal);
        if (decision.kind === 'error')
            return { kind: 'deny', reason: decision.reason };
        if (decision.kind === 'policy') {
            const downstream = await next();
            return downstream.kind === 'allow' ? { kind: 'ask', reason: decision.reason } : downstream;
        }
        if (decision.reason)
            ctx.logger.warn(decision.reason);
        return next();
    }, { prepend: true });
    ctx.on('tools/post-execute', async (exec, result, next) => {
        if (exec.name !== 'bash')
            return next();
        const decision = await runHook(ctx, options, toolPayload(exec, result), exec.signal);
        const downstream = await next();
        if (!decision.reason)
            return downstream;
        ctx.logger.warn(decision.reason);
        const notice = createUserMessage({
            content: [{ type: 'text', text: decision.reason }],
            source: { kind: 'vibeguard', form: 'notice', summary: 'VibeGuard observation warning' },
        });
        return { ...downstream, additionalContexts: [notice, ...downstream.additionalContexts ?? []] };
    });
}
