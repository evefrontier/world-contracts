import { bcs } from '@mysten/sui/bcs'
import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import type { WorldClient } from '../client.js'
import type { WorldConfig } from '../config/types.js'
import {
  completeRequest,
  componentIds,
  deleteEntity,
  deriveObjectId,
  entityNew,
  shareEntity,
  verifyAdmin,
} from '../packages/core.js'
import { createStorageUnit, uninstallInventory } from '../packages/inventory.js'
import {
  expectAbort,
  expectSuccess,
  loadLocalnetWorld,
  signer,
} from './helpers.js'

const MODULE_ID = 0x54n

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

  it('refuses the delete while a component is installed', async () => {
    const key = { id: 2421n, tenant: 'delete-entity' }
    const entityId = deriveObjectId(config, key)

    // A storage unit is an entity with one inventory component.
    const createTx = new Transaction()
    createStorageUnit(createTx, config, {
      inGameId: key.id,
      tenant: key.tenant,
      componentId: MODULE_ID,
      typeId: 1n,
      name: 'SU-04',
      capacity: 1000n,
    })
    await expectSuccess(client, createTx)
    expect(await readComponentIds(client, config, entityId)).toEqual([
      MODULE_ID,
    ])

    // The inventory is still installed, so the delete aborts.
    const deleteTx = new Transaction()
    deleteEntity(deleteTx, config, deleteTx.object(entityId))
    await expectAbort(client, deleteTx, signer, /EComponentsInstalled/)

    // Uninstall the inventory, then delete, in one transaction.
    const teardownTx = new Transaction()
    const e = teardownTx.object(entityId)
    uninstallInventory(teardownTx, config, e, MODULE_ID)
    deleteEntity(teardownTx, config, e)
    const deleted = await expectSuccess(client, teardownTx)

    const deletedIds = deleted.effects.changedObjects
      .filter((o) => o.idOperation === 'Deleted')
      .map((o) => o.objectId)
    expect(deletedIds).toContain(entityId)
  })
})

/** Read `entity::component_ids` with a simulated transaction. */
async function readComponentIds(
  client: WorldClient,
  config: WorldConfig,
  entityId: string,
): Promise<bigint[]> {
  const tx = new Transaction()
  tx.setSender(signer)
  componentIds(tx, config, tx.object(entityId))
  const res = await client.simulateTransaction({
    transaction: tx,
    include: { commandResults: true },
  })
  if (res.FailedTransaction) {
    throw new Error(
      `component_ids simulation failed: ${res.FailedTransaction.status.error?.message ?? ''}`,
    )
  }
  const rv = res.commandResults[0]?.returnValues[0]
  if (!rv) throw new Error('component_ids returned no value')
  return bcs
    .vector(bcs.u64())
    .parse(rv.bcs)
    .map((id) => BigInt(id))
}
