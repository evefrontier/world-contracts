import { fileURLToPath } from 'node:url'
import { getJsonRpcFullnodeUrl } from '@mysten/sui/jsonRpc'
import 'dotenv/config'
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519'
import { Transaction } from '@mysten/sui/transactions'
import { createWorldClient } from '../src/client.js'
import { envProfile } from '../src/config/env.js'
import { loadWorldConfig } from '../src/config/load.js'
import type { Env } from '../src/config/types.js'
import { addAdmins, addSponsors } from '../src/packages/core.js'

const DEPLOY_ENV = process.env.ENV ?? 'localnet'
const SDK_ENV = DEPLOY_ENV === 'localnet' ? 'local' : DEPLOY_ENV
const VALID_ENVS: readonly Env[] = ['local', 'dev', 'uat', 'test', 'live']
if (!VALID_ENVS.includes(SDK_ENV as Env)) {
  throw new Error(
    `unknown ENV "${DEPLOY_ENV}" (want localnet|${VALID_ENVS.join('|')})`,
  )
}
const env = SDK_ENV as Env
const MANIFEST = fileURLToPath(
  new URL(`../../../deployments/${DEPLOY_ENV}/world.json`, import.meta.url),
)

// Comma-separated list of addresses, e.g. 0x..,0x..
function addresses(name: string): string[] {
  return (process.env[name]?.split(',') ?? [])
    .map((a) => a.trim())
    .filter((a) => a.length > 0)
}

const admins = addresses('ADMIN_ADDRESSES')
const sponsors = addresses('SPONSOR_ADDRESSES')

if (admins.length === 0 && sponsors.length === 0) {
  console.log('no ADMIN_ADDRESSES or SPONSOR_ADDRESSES set; nothing to do.')
  process.exit(0)
}

const privateKey = process.env.SUI_PRIVATE_KEY
if (!privateKey) {
  throw new Error('SUI_PRIVATE_KEY is required (the deploying admin key)')
}
const keypair = Ed25519Keypair.fromSecretKey(privateKey)

const config = loadWorldConfig(MANIFEST)
const rpcUrl =
  env === 'local' ? undefined : getJsonRpcFullnodeUrl(envProfile(env).network)
const client = createWorldClient({ config, rpcUrl })

const tx = new Transaction()
if (admins.length > 0) addAdmins(tx, config, admins)
if (sponsors.length > 0) addSponsors(tx, config, sponsors)

const res = await client.signAndExecuteTransaction({
  signer: keypair,
  transaction: tx,
  options: { showEffects: true },
})

const status = res.effects?.status
console.log('status:', status?.status, status?.error ?? '')
console.log(
  `admins added: ${admins.length}, sponsors added: ${sponsors.length}`,
)

if (status?.status !== 'success') {
  process.exitCode = 1
}
