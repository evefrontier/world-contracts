import { Transaction } from '@mysten/sui/transactions'
import { describe, it } from 'vitest'
import {
  completeRequest,
  deriveObjectId,
  disableAction,
  disableAdminAction,
  enableAction,
  enableAdminAction,
  interact,
  ownerRequirement,
} from '../packages/core.js'
import {
  createStorageUnit,
  depositRequirement,
  uninstallInventory,
  withdrawRequirement,
} from '../packages/inventory.js'
import {
  expectAbort,
  expectSuccess,
  loadLocalnetWorld,
  mintAccessCap,
  signer,
} from './helpers.js'

// An admin removes an inventory module. Admin actions and owner actions live in
// two maps. The admin disables the admin action, the owner disables the owner
// action, then the admin uninstalls the module. After that, an interaction with
// each action aborts.
const MODULE_ID = 0x53n
const UNIT = 'SU-03'

describe('inventory uninstall with action cleanup (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('disables the actions on the inventory, then uninstalls it', async () => {
    const key = { id: 4300n, tenant: 'inventory-t3' }
    const entityId = deriveObjectId(config, key)

    // create + install + share the storage unit.
    const createTx = new Transaction()
    createStorageUnit(createTx, config, {
      inGameId: key.id,
      tenant: key.tenant,
      componentId: MODULE_ID,
      typeId: 1n,
      name: UNIT,
      capacity: 1000n,
    })
    await expectSuccess(client, createTx)

    // mint the owner cap to the signer.
    const capId = await mintAccessCap(client, config, {
      entity: entityId,
      owner: signer,
      transferable: true,
    })

    // the admin exposes deposit. The owner exposes withdraw.
    const enableTx = new Transaction()
    const entity = enableTx.object(entityId)
    enableAdminAction(enableTx, config, entity, 'deposit', [
      ownerRequirement(enableTx, config),
      depositRequirement(enableTx, config, MODULE_ID, {}),
    ])
    enableAction(
      enableTx,
      config,
      entity,
      'withdraw',
      [
        ownerRequirement(enableTx, config),
        withdrawRequirement(enableTx, config, MODULE_ID, {}),
      ],
      capId,
    )
    await expectSuccess(client, enableTx)

    // the admin map does not hold the owner's action.
    const wrongMapTx = new Transaction()
    disableAdminAction(
      wrongMapTx,
      config,
      wrongMapTx.object(entityId),
      'withdraw',
    )
    await expectAbort(client, wrongMapTx, signer, /EUnknownAction/)

    // the admin disables deposit, the owner disables withdraw, then the admin
    // uninstalls the inventory. The signer is admin and owner here.
    const removeTx = new Transaction()
    const e = removeTx.object(entityId)
    disableAdminAction(removeTx, config, e, 'deposit')
    disableAction(removeTx, config, e, 'withdraw', capId)
    uninstallInventory(removeTx, config, e, MODULE_ID)
    await expectSuccess(client, removeTx)

    // the actions are gone, so an interaction with each one aborts.
    for (const action of ['deposit', 'withdraw']) {
      const tx = new Transaction()
      const target = tx.object(entityId)
      const request = interact(tx, config, target, action)
      completeRequest(tx, config, target, request)
      await expectAbort(client, tx, signer, /EUnknownAction/)
    }
  })
})
