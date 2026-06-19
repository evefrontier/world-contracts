import { fileURLToPath } from 'node:url'
import 'dotenv/config'
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519'
import { Transaction } from '@mysten/sui/transactions'
import { createWorldClient } from '../src/client.js'
import { loadWorldConfig } from '../src/config/load.js'
import { createCharacter } from '../src/packages/character.js'
import { deriveObjectId } from '../src/packages/core.js'

const MANIFEST = fileURLToPath(
  new URL('../../../deployments/localnet/world.json', import.meta.url),
)

const privateKey = process.env.SUI_PRIVATE_KEY
if (!privateKey) {
  throw new Error(
    'SUI_PRIVATE_KEY is required (a funded localnet key, suiprivkey1...)',
  )
}
const keypair = Ed25519Keypair.fromSecretKey(privateKey)
const owner = keypair.toSuiAddress()

const key = {
  id: BigInt(process.env.ID ?? '7'),
  tenant: process.env.TENANT ?? 'my-tenant',
}
const tribeId = Number(process.env.TRIBE_ID ?? '1')

const config = loadWorldConfig(MANIFEST)
const client = createWorldClient({ config })

const tx = new Transaction()
createCharacter(tx, config, {
  inGameId: key.id,
  tenant: key.tenant,
  tribeId,
  owner,
})

const res = await client.signAndExecuteTransaction({
  signer: keypair,
  transaction: tx,
  options: { showEffects: true, showObjectChanges: true },
})

const status = res.effects?.status
if (status?.status !== 'success') {
  throw new Error(`transaction failed: ${status?.error ?? 'unknown error'}`)
}

console.log(
  JSON.stringify(
    {
      digest: res.digest,
      expectedObjectId: deriveObjectId(config, key),
      created: (res.effects?.created ?? []).map((c) => c.reference.objectId),
    },
    null,
    2,
  ),
)
