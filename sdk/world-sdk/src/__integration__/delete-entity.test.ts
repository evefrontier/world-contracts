import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import {
  completeRequest,
  deleteEntity,
  deriveObjectId,
  entityNew,
  shareEntity,
  verifyAdmin,
} from '../packages/core.js'
import { expectSuccess, loadLocalnetWorld } from './helpers.js'

describe('deleteEntity (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('deletes a shared entity with no modules', async () => {
    const key = { id: 2420n, tenant: 'delete-entity' }
    const entityId = deriveObjectId(config, key)

    const createTx = new Transaction()
    const [entity, claimReq] = entityNew(createTx, config, {
      inGameId: key.id,
      tenant: key.tenant,
    })
    verifyAdmin(createTx, config, claimReq)
    completeRequest(createTx, config, entity, claimReq)
    shareEntity(createTx, config, entity)
    await expectSuccess(client, createTx)

    const deleteTx = new Transaction()
    deleteEntity(deleteTx, config, deleteTx.object(entityId))
    const deleted = await expectSuccess(client, deleteTx)

    const deletedIds = deleted.effects.changedObjects
      .filter((o) => o.idOperation === 'Deleted')
      .map((o) => o.objectId)
    expect(deletedIds).toContain(entityId)
  })
})
