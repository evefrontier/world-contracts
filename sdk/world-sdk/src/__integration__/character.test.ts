import { fileURLToPath } from 'node:url'
import 'dotenv/config'
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519'
import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import { createWorldClient } from '../client.js'
import { loadWorldConfig } from '../config/load.js'
import { createCharacter } from '../packages/character.js'
import { deriveObjectId } from '../packages/core.js'

// Integration: exercises the createCharacter binding against a running localnet.
// Requires `pnpm deploy:localnet` (or equivalent) so deployments/localnet/world.json
// exists and the chain is up. Run with: pnpm --filter @evefrontier/world-sdk test:integration
const MANIFEST = fileURLToPath(
  new URL('../../../../deployments/localnet/world.json', import.meta.url),
)
const privateKey = process.env.SUI_PRIVATE_KEY
const SENDER =
  process.env.WORLD_ADMIN_ADDRESS ??
  (privateKey
    ? Ed25519Keypair.fromSecretKey(privateKey).toSuiAddress()
    : undefined)
if (!SENDER) {
  throw new Error(
    'WORLD_ADMIN_ADDRESS or SUI_PRIVATE_KEY is required (an admin)',
  )
}

describe('createCharacter (localnet)', () => {
  const config = loadWorldConfig(MANIFEST)
  const client = createWorldClient({ config })

  it('builds a character::create call the chain accepts, at the derived id', async () => {
    const key = { id: 7n, tenant: 'integration' }
    const tx = new Transaction()
    createCharacter(tx, config, {
      inGameId: key.id,
      tenant: key.tenant,
      tribeId: 1,
      owner: SENDER,
    })

    const res = await client.devInspectTransactionBlock({
      sender: SENDER,
      transactionBlock: tx,
    })

    expect(res.effects?.status?.status, res.effects?.status?.error ?? '').toBe(
      'success',
    )

    const created = (res.effects?.created ?? []).map(
      (c) => c.reference.objectId,
    )
    expect(created).toContain(deriveObjectId(config, key))
  })
})
