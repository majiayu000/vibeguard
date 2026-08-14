import { describe, expect, it } from 'vitest'
import { toolHookPlan } from '../src/index.js'

describe('toolHookPlan', () => {
  it.each([
    ['bash', 'Bash', ['pre-bash-guard'], ['post-build-check']],
    ['write', 'Write', ['pre-write-guard'], ['post-write-guard', 'post-build-check']],
    ['edit', 'Edit', ['pre-edit-guard'], ['post-edit-guard', 'post-build-check']],
    ['read', 'Read', [], ['analysis-paralysis-guard']],
    ['glob', 'Glob', [], ['analysis-paralysis-guard']],
    ['grep', 'Grep', [], ['analysis-paralysis-guard']],
  ])('maps %s to %s', (name, canonicalName, preHooks, postHooks) => {
    const plan = toolHookPlan({ name, arguments: {} })
    expect(plan).toMatchObject({ canonicalName, preHooks, postHooks })
  })

  it('maps editor create to canonical Write fields', () => {
    const plan = toolHookPlan({
      name: 'str_replace_editor',
      arguments: { command: 'create', path: '/repo/a.ts', file_text: 'hello' },
    })
    expect(plan).toMatchObject({
      canonicalName: 'Write', mutation: true,
      input: { file_path: '/repo/a.ts', content: 'hello' },
    })
  })

  it('maps editor replacement to canonical Edit fields', () => {
    const plan = toolHookPlan({
      name: 'str_replace_editor',
      arguments: { command: 'str_replace', path: '/repo/a.ts', old_str: 'a', new_str: 'b' },
    })
    expect(plan).toMatchObject({
      canonicalName: 'Edit', mutation: true,
      input: { file_path: '/repo/a.ts', old_string: 'a', new_string: 'b' },
    })
  })

  it('treats editor view as Read without a mutation', () => {
    const plan = toolHookPlan({
      name: 'str_replace_editor', arguments: { command: 'view', path: '/repo/a.ts' },
    })
    expect(plan).toMatchObject({
      canonicalName: 'Read', mutation: false, postHooks: ['analysis-paralysis-guard'],
    })
  })

  it('leaves unknown tools untouched', () => {
    expect(toolHookPlan({ name: 'custom', arguments: { x: 1 } })).toMatchObject({
      canonicalName: 'Other', preHooks: [], postHooks: [], mutation: false,
    })
  })
})
