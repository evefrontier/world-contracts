import { fileURLToPath } from 'node:url'
import 'dotenv/config'
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519'
import { Transaction } from '@mysten/sui/transactions'
import { createWorldClient } from '../src/client.js'
import { loadWorldConfig } from '../src/config/load.js'
import { addAdmins, addSponsors } from '../src/packages/core.js'

const ENV = process.env.ENV ?? 'localnet'
const MANIFEST = fileURLToPath(
  new URL(`../../../deployments/${ENV}/world.json`, import.meta.url),
)

function addresses(name: string): string[] {
  const raw = process.env[name]
  if (!raw) return []
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    throw new Error(
      `${name} must be a JSON array of addresses, e.g. ["0x..","0x.."]`,
    )
  }
  if (!Array.isArray(parsed) || !parsed.every((a) => typeof a === 'string')) {
    throw new Error(`${name} must be a JSON array of address strings`)
  }
  return parsed
}

const privateKey = process.env.SUI_PRIVATE_KEY
if (!privateKey) {
  throw new Error('SUI_PRIVATE_KEY is required (the deploying admin key)')
}
const keypair = Ed25519Keypair.fromSecretKey(privateKey)

const admins = addresses('ADMIN_ADDRESS')
const sponsors = addresses('SPONSOR_ADDRESSES')

if (admins.length === 0 && sponsors.length === 0) {
  console.log('no ADMIN_ADDRESS or SPONSOR_ADDRESSES set; nothing to do.')
  process.exit(0)
}

const config = loadWorldConfig(MANIFEST)
const client = createWorldClient({ config })

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
