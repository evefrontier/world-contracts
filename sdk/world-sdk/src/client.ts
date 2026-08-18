import type { SuiClientTypes } from '@mysten/sui/client'
import { getJsonRpcFullnodeUrl, SuiJsonRpcClient } from '@mysten/sui/jsonRpc'
import { type EnvProfile, envProfile, mvrName } from './config/env.js'
import { getWorldConfig } from './config/presets.js'
import type { Env, Network, WorldConfig } from './config/types.js'

const MVR_ENDPOINT: Partial<Record<Network, string>> = {
  testnet: 'https://testnet.mvr.mystenlabs.com',
  mainnet: 'https://mainnet.mvr.mystenlabs.com',
}

export type CreateWorldClientOptions =
  | { env: Exclude<Env, 'local'>; rpcUrl?: string }
  | { config: WorldConfig; rpcUrl?: string }

/**
 * A SuiJsonRpcClient wired to resolve `@evefrontier/world-*` (and
 * `@evefrontier/currency*`) MVR names: from the registry on testnet/mainnet,
 * from `packageOverrides` on local. Names in a transaction's move calls resolve
 * automatically when built/executed with it.
 */
export function createWorldClient(
  options: CreateWorldClientOptions,
): SuiJsonRpcClient {
  const config =
    'config' in options ? options.config : getWorldConfig(options.env)
  const profile = envProfile(config.env)
  const url = options.rpcUrl ?? getJsonRpcFullnodeUrl(profile.network)
  return new SuiJsonRpcClient({
    url,
    network: profile.network,
    mvr: mvrOptions(config, profile),
  })
}

function mvrOptions(
  config: WorldConfig,
  profile: EnvProfile,
): SuiClientTypes.MvrOptions {
  const { network, mvrMode } = profile
  switch (mvrMode) {
    case 'overrides': {
      const packages: Record<string, string> = {}
      for (const [pkg, id] of Object.entries(config.packageOverrides ?? {})) {
        packages[mvrName(config.env, pkg)] = id
      }
      return { overrides: { packages } }
    }
    case 'registry': {
      const url = MVR_ENDPOINT[network]
      return url ? { url } : {}
    }
    default: {
      const _exhaustive: never = mvrMode
      return _exhaustive
    }
  }
}
