import { defineConfig } from 'vitest/config'

// Integration tests for the contract-API bindings, run against a live localnet.
// Opt-in: `pnpm --filter @evefrontier/world-sdk test:integration` (needs a
// localnet up and deployments/localnet/world.json present). Not part of CI.
export default defineConfig({
  test: {
    include: ['src/**/__integration__/**/*.test.ts'],
    exclude: ['node_modules', 'dist'],
  },
})
