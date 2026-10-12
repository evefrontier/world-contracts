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
import { createStorageUnit, uninstallInventory } from '../packages/inventory.js'
import { uninstallPowerGrid } from '../packages/power.js'
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

    // A storage unit carries its inventory and the power grid the inventory connects to.
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

    // The inventory is still installed, so the delete aborts.
    const deleteTx = new Transaction()
    deleteEntity(deleteTx, config, deleteTx.object(entityId))
    await expectAbort(client, deleteTx, signer, /EComponentsInstalled/)

    // Uninstall the inventory, then delete, in one transaction.
    const teardownTx = new Transaction()
    const e = teardownTx.object(entityId)
    uninstallInventory(teardownTx, config, e, MODULE_ID)
    uninstallPowerGrid(teardownTx, config, e)
    deleteEntity(teardownTx, config, e)
    const deleted = await expectSuccess(client, teardownTx)

    const deletedIds = deleted.effects.changedObjects
      .filter((o) => o.idOperation === 'Deleted')
      .map((o) => o.objectId)
    expect(deletedIds).toContain(entityId)
  })
})
