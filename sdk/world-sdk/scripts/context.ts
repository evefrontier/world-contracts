import { fileURLToPath } from 'node:url'
import 'dotenv/config'
import { fromNodeProviderChain } from '@aws-sdk/credential-providers'
import { AwsKmsSigner } from '@mysten/aws-kms-signer'
import type { Signer } from '@mysten/sui/cryptography'
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519'
import {
  createWorldClient,
  grpcUrlForNetwork,
  type WorldClient,
} from '../src/client.js'
import { envProfile } from '../src/config/env.js'
import { loadWorldConfig } from '../src/config/load.js'
import type { Env, WorldConfig } from '../src/config/types.js'

const VALID_ENVS: readonly Env[] = ['local', 'dev', 'uat', 'test', 'live']

function isEnv(value: string): value is Env {
  return (VALID_ENVS as readonly string[]).includes(value)
}

export interface ScriptContext {
  deployEnv: string
  env: Env
  repoRoot: string
  manifestPath: string
  config: WorldConfig
  client: WorldClient
  signer: Signer
}

export async function loadScriptContext(): Promise<ScriptContext> {
  const deployEnv = process.env.ENV ?? 'localnet'
  const env = deployEnv === 'localnet' ? 'local' : deployEnv
  if (!isEnv(env)) {
    throw new Error(
      `unknown ENV "${deployEnv}" (want localnet|${VALID_ENVS.join('|')})`,
    )
  }
  const repoRoot = fileURLToPath(new URL('../../..', import.meta.url))
  const manifestPath = `${repoRoot}/deployments/${deployEnv}/world.json`

  const signer = await loadSigner()

  const config = loadWorldConfig(manifestPath)
  const grpcUrl =
    process.env.SUI_GRPC_URL ??
    (env === 'local'
      ? process.env.SUI_RPC_URL
      : grpcUrlForNetwork(envProfile(env).network))
  const client = createWorldClient({ config, grpcUrl })

  return { deployEnv, env, repoRoot, manifestPath, config, client, signer }
}

// The deploying admin key: an AWS KMS key (SUINS_KMS_KEY_ID) or SUI_PRIVATE_KEY.
async function loadSigner(): Promise<Signer> {
  const kmsKeyId = process.env.SUINS_KMS_KEY_ID
  if (kmsKeyId) {
    const region =
      process.env.AWS_REGION ??
      process.env.AWS_DEFAULT_REGION ??
      (kmsKeyId.startsWith('arn:aws:kms:') ? kmsKeyId.split(':')[3] : undefined)
    if (!region) throw new Error('Set AWS_REGION or use a full KMS key ARN')
    return AwsKmsSigner.fromKeyId(kmsKeyId, {
      region,
      credentials: fromNodeProviderChain(),
    })
  }
  const privateKey = process.env.SUI_PRIVATE_KEY
  if (!privateKey) {
    throw new Error(
      'SUI_PRIVATE_KEY or SUINS_KMS_KEY_ID is required (the deploying admin key)',
    )
  }
  return Ed25519Keypair.fromSecretKey(privateKey)
}
