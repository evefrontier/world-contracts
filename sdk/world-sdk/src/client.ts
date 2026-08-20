import type { SuiClientTypes } from '@mysten/sui/client'
import type { Signer } from '@mysten/sui/cryptography'
import { SuiGrpcClient } from '@mysten/sui/grpc'
import type { Transaction } from '@mysten/sui/transactions'
import { type EnvProfile, envProfile, mvrName } from './config/env.js'
import { getWorldConfig } from './config/presets.js'
import type { Env, Network, WorldConfig } from './config/types.js'

const MVR_ENDPOINT: Partial<Record<Network, string>> = {
  testnet: 'https://testnet.mvr.mystenlabs.com',
  mainnet: 'https://mainnet.mvr.mystenlabs.com',
}

const DEFAULT_GRPC_URLS: Record<Network, string> = {
  localnet: 'http://127.0.0.1:9000',
  testnet: 'https://fullnode.testnet.sui.io:443',
  mainnet: 'https://fullnode.mainnet.sui.io:443',
}

export type WorldClient = SuiGrpcClient

export type ExecutedTransaction = SuiClientTypes.Transaction<{
  effects: true
  events: true
  objectTypes: true
}>

export type CreateWorldClientOptions = (
  | { env: Exclude<Env, 'local'> }
  | { config: WorldConfig }
) & { grpcUrl?: string; rpcUrl?: string }

/**
 * A SuiGrpcClient wired to resolve `@evefrontier/world-*` (and
 * `@evefrontier/currency*`) MVR names: from the registry on testnet/mainnet,
 * from `packageOverrides` on local. Names in a transaction's move calls resolve
 * automatically when built/executed with it.
 */
export function createWorldClient(
  options: CreateWorldClientOptions,
): WorldClient {
  const config =
    'config' in options ? options.config : getWorldConfig(options.env)
  const profile = envProfile(config.env)
  const url =
    options.grpcUrl ?? options.rpcUrl ?? DEFAULT_GRPC_URLS[profile.network]
  return new SuiGrpcClient({
    network: profile.network,
    baseUrl: url,
    mvr: mvrOptions(config, profile),
  })
}

export function requireExecutedTx<
  Include extends SuiClientTypes.TransactionInclude,
>(
  result: SuiClientTypes.TransactionResult<Include>,
): SuiClientTypes.Transaction<Include> {
  if (result.FailedTransaction) {
    const error = result.FailedTransaction.status.error
    throw new Error(`Transaction failed: ${error?.message ?? 'unknown error'}`)
  }
  return result.Transaction
}

export async function signAndExecute(
  client: WorldClient,
  input: {
    transaction: Transaction
    signer: Signer
  },
): Promise<ExecutedTransaction> {
  const result = await client.signAndExecuteTransaction({
    transaction: input.transaction,
    signer: input.signer,
    include: { effects: true, events: true, objectTypes: true },
  })
  return requireExecutedTx(result)
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
