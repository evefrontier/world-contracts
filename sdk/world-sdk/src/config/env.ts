import type { Env, Network } from './types.js'

export const MVR_ORG = '@evefrontier'

export type MvrMode = 'overrides' | 'registry'

export interface EnvProfile {
  network: Network
  mvrMode: MvrMode
  suffix: string
}

// Record keyed by Env: a new env variant fails to compile until added here.
const ENV_PROFILES: Record<Env, EnvProfile> = {
  local: { network: 'localnet', mvrMode: 'overrides', suffix: '' },
  dev: { network: 'testnet', mvrMode: 'registry', suffix: '-dev' },
  uat: { network: 'testnet', mvrMode: 'registry', suffix: '-uat' },
  test: { network: 'testnet', mvrMode: 'registry', suffix: '-test' },
  live: { network: 'mainnet', mvrMode: 'registry', suffix: '' },
}

export function envProfile(env: Env): EnvProfile {
  return ENV_PROFILES[env]
}

// e.g. mvrName("dev", "core") -> "@evefrontier/world-core-dev"
export function mvrName(env: Env, pkg: string): string {
  return `${MVR_ORG}/world-${pkg}${envProfile(env).suffix}`
}
