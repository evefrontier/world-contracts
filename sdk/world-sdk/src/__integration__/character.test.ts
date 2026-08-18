import { fileURLToPath } from 'node:url'
import 'dotenv/config'
import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import { createWorldClient } from '../client.js'
import { loadWorldConfig } from '../config/load.js'
import { createCharacter } from '../packages/character.js'
import { deriveObjectId } from '../packages/core.js'

// Integration: exercises the createCharacter binding against a running localnet.
const MANIFEST = fileURLToPath(
  new URL('../../../../deployments/localnet/world.json', import.meta.url),
)
const ADMIN = process.env.WORLD_ADMIN_ADDRESS
if (!ADMIN) {
  throw new Error('WORLD_ADMIN_ADDRESS is required (an admin)')
}

describe('createCharacter (localnet)', () => {
  const config = loadWorldConfig(MANIFEST)
  const client = createWorldClient({ config })

  it('builds a character-creation PTB the chain accepts, at the derived id', async () => {
    const key = { id: 7n, tenant: 'integration' }
    const tx = new Transaction()
    createCharacter(tx, config, {
      inGameId: key.id,
      tenant: key.tenant,
      tribeId: 1,
      owner: ADMIN,
    })

    // Simulate only needs a sender address; must be an admin for this call.
    tx.setSender(ADMIN)
    const res = await client.simulateTransaction({
      transaction: tx,
      include: { effects: true },
    })
    if (res.$kind !== 'Transaction') {
      throw new Error(
        res.FailedTransaction.status.error?.message ?? 'simulation failed',
      )
    }

    const created = res.Transaction.effects.changedObjects
      .filter((o) => o.idOperation === 'Created')
      .map((o) => o.objectId)
    expect(created).toContain(deriveObjectId(config, key))
  })
})
