/** Native DeepSeek Harness adapter for the installed VibeGuard runtime. */
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createUserMessage } from '@deepseek-ai/dsh-llm';
import { Config as ConfigSchema, DEFAULT_VERIFICATION_PATTERNS } from './config.js';
import { guardDecision, mergeDecisions, serializeDecision } from './decision.js';
import { HookRunner } from './hook-runner.js';
import { StartupGate, StopTracker, VerificationTracker } from './lifecycle.js';
import { currentTurn, sessionPayload, stopPayload, toolHookPlan, toolPayload } from './payloads.js';
import { HOOK_IDS } from './types.js';
export const name = 'vibeguard-dsh';
export const inject = ['shell'];
export const Config = ConfigSchema;
export { HOOK_IDS };
export * from './decision.js';
export * from './lifecycle.js';
export * from './payloads.js';
export * from './types.js';
function compilePatterns(patterns) {
    return patterns.map((pattern, index) => {
        try {
            return new RegExp(pattern, 'iu');
        }
        catch (error) {
            throw new Error(`vibeguard-dsh: verificationCommandPatterns[${index}] is invalid: ${String(error)}`);
        }
    });
}
function context(decision, summary) {
    return createUserMessage({
        content: [{ type: 'text', text: serializeDecision(decision) }],
        source: { kind: 'plugin', plugin: name, form: 'notice', summary },
    });
}
function prepend(ours, theirs) {
    return [ours, ...theirs ?? []];
}
function workdir(agent) {
    return agent?.session.header.cwd ?? process.cwd();
}
/** Install all configured VibeGuard lifecycle adapters into DSH. */
export function apply(ctx, config) {
    const hooksDir = config.hooksDir === undefined || config.hooksDir === ''
        ? join(homedir(), '.vibeguard', 'installed', 'hooks')
        : config.hooksDir;
    const resolved = {
        ...config,
        enabledHooks: config.enabledHooks ?? [...HOOK_IDS],
    };
    const runner = new HookRunner(ctx, hooksDir, resolved);
    const gate = new StartupGate();
    const stops = new StopTracker();
    const mutatingTools = new Set(config.mutatingTools ?? ['write', 'edit', 'str_replace_editor']);
    if ([...mutatingTools].some(tool => tool.trim() === '')) {
        throw new Error('vibeguard-dsh: mutatingTools must not contain empty names');
    }
    const tracker = new VerificationTracker(mutatingTools, compilePatterns(config.verificationCommandPatterns ?? DEFAULT_VERIFICATION_PATTERNS));
    ctx.effect(() => async () => gate.dispose(), 'vibeguard-dsh: drain SessionStart hook');
    ctx.on('agent/session-start', ({ agent, source }) => {
        if (!runner.has('count-active-constraints'))
            return;
        gate.start(agent, signal => runner.run('count-active-constraints', sessionPayload(agent, source), workdir(agent), signal));
    });
    ctx.on('agent/pre-step', async ({ agent }, next) => {
        const startup = await gate.take(agent);
        if (startup?.decision === 'deny')
            return { kind: 'reject' };
        const downstream = await next();
        if (startup === undefined || startup.signals.length === 0 || downstream.kind !== 'enter')
            return downstream;
        return { kind: 'enter', messages: [...downstream.messages, context(startup, 'VibeGuard startup check')] };
    });
    ctx.on('tools/pre-execute', async (exec, next) => {
        const plan = toolHookPlan(exec);
        if (plan.preHooks.length === 0)
            return next();
        const decision = await runner.runMany(plan.preHooks, toolPayload(exec, plan, 'PreToolUse'), workdir(exec.agent), exec.signal);
        if (decision.decision === 'deny')
            return { kind: 'deny', reason: serializeDecision(decision) };
        if (decision.signals.length > 0 && exec.agent) {
            exec.agent.inject(context(decision, `VibeGuard ${plan.canonicalName} pre-check`));
        }
        return next();
    }, { prepend: true });
    ctx.on('tools/post-execute', async (exec, result, next) => {
        const plan = toolHookPlan(exec);
        if (plan.postHooks.length === 0)
            return next();
        const decision = await runner.runMany(plan.postHooks, toolPayload(exec, plan, 'PostToolUse', result), workdir(exec.agent), exec.signal);
        if (decision.decision === 'deny') {
            return { kind: 'block', feedback: [{ type: 'text', text: serializeDecision(decision) }] };
        }
        const downstream = await next();
        if (decision.signals.length === 0)
            return downstream;
        const notice = context(decision, `VibeGuard ${plan.canonicalName} post-check`);
        return { ...downstream, additionalContexts: prepend(notice, downstream.additionalContexts) };
    });
    ctx.on('tools/result', (exec, result) => {
        const plan = toolHookPlan(exec);
        tracker.observe(exec, plan, exec.agent === undefined ? 0 : currentTurn(exec.agent), result);
    });
    ctx.on('agent/turn-stopping', async ({ agent, turn, signal }) => {
        let stopDecision = guardDecision('allow');
        if (stops.first(agent, turn)) {
            stopDecision = await runner.runMany(['stop-guard', 'learn-evaluator'], stopPayload(agent, turn, false), workdir(agent), signal);
        }
        const completion = config.guardUnverifiedCompletion ?? true
            ? tracker.completionSignal(agent, turn)
            : undefined;
        if (completion !== undefined || stopDecision.decision === 'deny') {
            const decision = mergeDecisions([
                guardDecision('continue', stopDecision.signals),
                ...completion === undefined ? [] : [guardDecision('continue', [completion])],
            ]);
            agent.steer(context(decision, 'VibeGuard requires another step'));
            return;
        }
        if (stopDecision.signals.length > 0) {
            agent.inject(context(stopDecision, 'VibeGuard stop advisory'));
        }
    });
}
