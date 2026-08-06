import { fileURLToPath } from 'node:url'
import {
  getJsonRpcFullnodeUrl,
  type SuiJsonRpcClient,
} from '@mysten/sui/jsonRpc'
import 'dotenv/config'
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519'
import { createWorldClient } from '../src/client.js'
import { envProfile } from '../src/config/env.js'
import { loadWorldConfig } from '../src/config/load.js'
import type { Env, WorldConfig } from '../src/config/types.js'

const VALID_ENVS: readonly Env[] = ['local', 'dev', 'uat', 'test', 'live']

export interface ScriptContext {
  deployEnv: string
  env: Env
  repoRoot: string
  manifestPath: string
  config: WorldConfig
  client: SuiJsonRpcClient
  keypair: Ed25519Keypair
}

export function loadScriptContext(): ScriptContext {
  const deployEnv = process.env.ENV ?? 'localnet'
  const sdkEnv = deployEnv === 'localnet' ? 'local' : deployEnv
  if (!VALID_ENVS.includes(sdkEnv as Env)) {
    throw new Error(
      `unknown ENV "${deployEnv}" (want localnet|${VALID_ENVS.join('|')})`,
    )
  }
  const env = sdkEnv as Env
  const repoRoot = fileURLToPath(new URL('../../..', import.meta.url))
  const manifestPath = `${repoRoot}/deployments/${deployEnv}/world.json`

  const privateKey = process.env.SUI_PRIVATE_KEY
  if (!privateKey) {
    throw new Error('SUI_PRIVATE_KEY is required (the deploying admin key)')
  }
  const keypair = Ed25519Keypair.fromSecretKey(privateKey)

  const config = loadWorldConfig(manifestPath)
  const rpcUrl =
    env === 'local' ? undefined : getJsonRpcFullnodeUrl(envProfile(env).network)
  const client = createWorldClient({ config, rpcUrl })

  return { deployEnv, env, repoRoot, manifestPath, config, client, keypair }
}
