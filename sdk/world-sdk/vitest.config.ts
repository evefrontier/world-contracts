import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    include: ['src/**/*.test.ts'],
    exclude: ['**/__integration__/**', 'node_modules', 'dist'],
  },
})
