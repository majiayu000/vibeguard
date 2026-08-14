/** DSH tool/session values translated to canonical VibeGuard hook payloads. */
function objectRecord(value) {
    return typeof value === 'object' && value !== null ? value : {};
}
function stringField(value, name) {
    return typeof value[name] === 'string' ? value[name] : '';
}
function directPlan(name, input) {
    switch (name) {
        case 'bash':
            return { canonicalName: 'Bash', input, preHooks: ['pre-bash-guard'], postHooks: ['post-build-check'], mutation: false };
        case 'write':
            return { canonicalName: 'Write', input, preHooks: ['pre-write-guard'], postHooks: ['post-write-guard', 'post-build-check'], mutation: true };
        case 'edit':
            return { canonicalName: 'Edit', input, preHooks: ['pre-edit-guard'], postHooks: ['post-edit-guard', 'post-build-check'], mutation: true };
        case 'read':
            return { canonicalName: 'Read', input, preHooks: [], postHooks: ['analysis-paralysis-guard'], mutation: false };
        case 'glob':
            return { canonicalName: 'Glob', input, preHooks: [], postHooks: ['analysis-paralysis-guard'], mutation: false };
        case 'grep':
            return { canonicalName: 'Grep', input, preHooks: [], postHooks: ['analysis-paralysis-guard'], mutation: false };
        default:
            return undefined;
    }
}
function editorPlan(input) {
    const command = stringField(input, 'command');
    const path = stringField(input, 'path');
    if (command === 'view') {
        return {
            canonicalName: 'Read', input: { file_path: path, ...input }, preHooks: [],
            postHooks: ['analysis-paralysis-guard'], mutation: false,
        };
    }
    if (command === 'create') {
        return {
            canonicalName: 'Write', input: { file_path: path, content: stringField(input, 'file_text') },
            preHooks: ['pre-write-guard'], postHooks: ['post-write-guard', 'post-build-check'], mutation: true,
        };
    }
    return {
        canonicalName: 'Edit',
        input: {
            file_path: path,
            old_string: stringField(input, 'old_str'),
            new_string: stringField(input, 'new_str'),
            ...input.insert_line === undefined ? {} : { insert_line: input.insert_line },
        },
        preHooks: ['pre-edit-guard'],
        postHooks: ['post-edit-guard', 'post-build-check'],
        mutation: command === 'str_replace' || command === 'insert',
    };
}
/** Map one DSH tool call to the canonical VibeGuard matcher and hook set. */
export function toolHookPlan(exec) {
    const input = objectRecord(exec.arguments);
    const direct = directPlan(exec.name, input);
    if (direct !== undefined)
        return direct;
    if (exec.name === 'str_replace_editor')
        return editorPlan(input);
    return { canonicalName: 'Other', input, preHooks: [], postHooks: [], mutation: false };
}
function base(agent, event) {
    return {
        session_id: agent?.session.header.id ?? '',
        transcript_path: null,
        cwd: agent?.session.header.cwd ?? process.cwd(),
        hook_event_name: event,
        permission_mode: 'default',
    };
}
function resultText(result) {
    return result.content
        .filter((block) => block.type === 'text')
        .map(block => block.text)
        .join('\n');
}
/** Build the SessionStart payload consumed by count-active-constraints. */
export function sessionPayload(agent, source) {
    return { ...base(agent, 'SessionStart'), source };
}
/** Build a complete PreToolUse/PostToolUse payload from one DSH tool call. */
export function toolPayload(exec, plan, event, result) {
    return {
        ...base(exec.agent, event),
        tool_name: plan.canonicalName,
        tool_input: plan.input,
        tool_use_id: exec.callId,
        ...result === undefined ? {} : { tool_response: resultText(result) },
    };
}
/** Build a Stop payload and expose whether this turn already reached a stop boundary. */
export function stopPayload(agent, turn, active) {
    return {
        ...base(agent, 'Stop'),
        turn_id: String(turn),
        stop_hook_active: active,
        last_assistant_message: null,
    };
}
/** Locate the open DSH turn for tool-result correlation. */
export function currentTurn(agent) {
    const events = agent.session.events;
    for (let index = events.length - 1; index >= 0; index -= 1) {
        const event = events[index];
        if (event?.type === 'turn/start')
            return event.data.turn;
    }
    return 0;
}
