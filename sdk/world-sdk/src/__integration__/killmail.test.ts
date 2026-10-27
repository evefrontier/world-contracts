import { fileURLToPath } from 'node:url'
import 'dotenv/config'
import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import { createWorldClient } from '../client.js'
import { loadWorldConfig } from '../config/load.js'
import { createCharacter } from '../packages/character.js'
import { deriveObjectId } from '../packages/core.js'
import { createKillmail, LOSS_TYPE_SHIP } from '../packages/killmail.js'
import { expectSuccess } from './helpers.js'

// Integration: exercises the createCharacter binding against a running localnet.
const MANIFEST = fileURLToPath(
  new URL('../../../../deployments/localnet/world.json', import.meta.url),
)
const ADMIN = process.env.WORLD_ADMIN_ADDRESS
if (!ADMIN) {
  throw new Error('WORLD_ADMIN_ADDRESS is required (an admin)')
}

const PLAYER =
  '0x000000000000000000000000000000000000000000000000000000000000000b'

describe('createKillmail (localnet)', () => {
  const config = loadWorldConfig(MANIFEST)
  const client = createWorldClient({ config })

  it('builds a killmail-creation PTB the chain accepts, at the derived id', async () => {
    const key = { id: 7n, tenant: 'integration' }
    const reporterId = 5n

    // The reporter must already exist on-chain as a character (identity installed).
    const setupTx = new Transaction()
    createCharacter(setupTx, config, {
      inGameId: reporterId,
      tenant: key.tenant,
      tribeId: 1,
      owner: PLAYER,
    })
    await expectSuccess(client, setupTx)

    const tx = new Transaction()
    createKillmail(tx, config, {
      inGameId: key.id,
      tenant: key.tenant,
      killerId: BigInt(1),
      victimId: BigInt(2),
      lossType: LOSS_TYPE_SHIP,
      solarSystemId: BigInt(4),
      reporterId,
      killTime: BigInt(Math.floor(Date.now() / 1000)), // Current time in seconds
    })

    // Admin-gated create; character is owned by PLAYER.
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
