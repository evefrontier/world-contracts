import { describe, expect, it } from 'vitest'
import { moduleIdFromName } from './module-id.js'

describe('moduleIdFromName', () => {
  it('is a deterministic u64', () => {
    const identity = moduleIdFromName('identity')
    expect(identity).toBe(moduleIdFromName('identity'))
    expect(identity).toBeGreaterThan(0n)
    expect(identity).toBeLessThan(1n << 64n)
    expect(moduleIdFromName('metadata')).not.toBe(identity)
  })
})
