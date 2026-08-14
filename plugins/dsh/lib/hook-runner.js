/** Execute canonical VibeGuard scripts through DSH's managed shell service. */
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { interpretHookResult, mergeDecisions, serializeDecision } from './decision.js';
import { HOOK_IDS } from './types.js';
const SCRIPT_NAMES = {
    'count-active-constraints': 'count_active_constraints.sh',
    'pre-bash-guard': 'pre-bash-guard.sh',
    'pre-edit-guard': 'pre-edit-guard.sh',
    'pre-write-guard': 'pre-write-guard.sh',
    'post-edit-guard': 'post-edit-guard.sh',
    'post-write-guard': 'post-write-guard.sh',
    'post-build-check': 'post-build-check.sh',
    'analysis-paralysis-guard': 'analysis-paralysis-guard.sh',
    'stop-guard': 'stop-guard.sh',
    'learn-evaluator': 'learn-evaluator.sh',
};
function positiveInteger(field, value) {
    if (!Number.isInteger(value) || value < 1) {
        throw new Error(`vibeguard-dsh: ${field} must be a positive integer`);
    }
    return value;
}
function shellQuote(value) {
    return `'${value.replaceAll("'", `'\\''`)}'`;
}
/** Validated, lifecycle-safe executor for the selected canonical hook scripts. */
export class HookRunner {
    ctx;
    hooksDir;
    buildTimeoutMs;
    enabled;
    failureMode;
    stdoutMaxBytes;
    timeoutMs;
    constructor(ctx, hooksDir, config) {
        this.ctx = ctx;
        this.hooksDir = hooksDir;
        this.timeoutMs = positiveInteger('timeoutMs', config.timeoutMs ?? 15_000);
        this.buildTimeoutMs = positiveInteger('buildTimeoutMs', config.buildTimeoutMs ?? 35_000);
        this.stdoutMaxBytes = positiveInteger('stdoutMaxBytes', config.stdoutMaxBytes ?? 65_536);
        this.failureMode = config.failureMode ?? 'closed';
        this.enabled = new Set(config.enabledHooks ?? HOOK_IDS);
        for (const hook of this.enabled) {
            const path = this.path(hook);
            if (!existsSync(path))
                throw new Error(`vibeguard-dsh: hook not found at ${path}`);
        }
    }
    /** Whether one canonical hook is enabled in this deployment. */
    has(hook) {
        return this.enabled.has(hook);
    }
    path(hook) {
        return join(this.hooksDir, SCRIPT_NAMES[hook]);
    }
    /** Run one hook and record its stable structured decision. */
    async run(hook, payload, workdir, signal) {
        if (!this.has(hook))
            return mergeDecisions([]);
        let decision;
        try {
            const result = await this.ctx.shell.run(this.ctx.shell.resolve({
                command: `bash ${shellQuote(this.path(hook))}`,
                workdir,
                timeoutMs: hook === 'post-build-check' ? this.buildTimeoutMs : this.timeoutMs,
                stdoutMaxBytes: this.stdoutMaxBytes,
                signal,
                stdin: JSON.stringify(payload),
                env: {
                    VIBEGUARD_AGENT_TYPE: 'dsh',
                    VIBEGUARD_CALLER_EVIDENCE: 'dsh-native-hook-payload',
                    VIBEGUARD_CLI: 'dsh',
                    VIBEGUARD_CLIENT: 'dsh',
                    VIBEGUARD_CLIENT_VARIANT: 'dsh-native-plugin',
                    VIBEGUARD_HOOK_PROTOCOL_VERSION: 'dsh-native-v1',
                    VIBEGUARD_PROJECT_ROOT: workdir,
                },
            }));
            decision = interpretHookResult(hook, {
                exitCode: result.exitCode,
                signal: result.signal,
                timedOut: result.timedOut,
                aborted: result.aborted,
                stdout: result.stdout.text,
                stderr: result.stderr.text,
                stdoutTruncated: result.stdout.truncated,
            }, this.failureMode);
        }
        catch (error) {
            const reason = `VibeGuard shell execution failed: ${error instanceof Error ? error.message : String(error)}`;
            decision = interpretHookResult(hook, {
                exitCode: 1, signal: null, timedOut: false, aborted: false, stdout: '', stderr: reason,
            }, this.failureMode);
        }
        this.ctx.logger.info(`vibeguard-dsh hook=${hook} decision=${serializeDecision(decision)}`);
        return decision;
    }
    /** Run a hook sequence in manifest order and combine its signals. */
    async runMany(hooks, payload, workdir, signal) {
        const decisions = [];
        for (const hook of hooks) {
            if (this.has(hook))
                decisions.push(await this.run(hook, payload, workdir, signal));
        }
        return mergeDecisions(decisions);
    }
}
