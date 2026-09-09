import { describe, expect, it } from 'vitest'
import { componentIdFromName } from './component-id.js'

describe('componentIdFromName', () => {
  it('is a deterministic u64', () => {
    const identity = componentIdFromName('identity')
    expect(identity).toBe(componentIdFromName('identity'))
    expect(identity).toBeGreaterThan(0n)
    expect(identity).toBeLessThan(1n << 64n)
    expect(componentIdFromName('metadata')).not.toBe(identity)
  })
})
