import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import {
  completeRequest,
  deriveObjectId,
  enableAction,
  interact,
  ownerRequirement,
  verifyOwner,
  verifyProximity,
} from '../packages/core.js'
import {
  bridgeInRequirement,
  createStorageUnit,
  deposit,
  depositRequirement,
  gameItemToChain,
  withdraw,
  withdrawRequirement,
} from '../packages/inventory.js'
import {
  expectSuccess,
  loadLocalnetWorld,
  mintAccessCap,
  readBalance,
  signer,
} from './helpers.js'

// Exercise the inventory bindings in isolation. Create a storage-unit entity,
// mint the owner cap to a plain address, enable owner-gated deposit/withdraw/
// bridge actions, then round-trip a balance: bridge_in seeds it, withdraw
// yields an Item, deposit puts it back.
const MODULE_ID = 0x51n
const UNIT = 'SU-01'
const FUEL = 88834n
const VOL = 2n

describe('inventory owner round-trip (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('bridges in, withdraws, and deposits back on the inventory', async () => {
    const key = { id: 4200n, tenant: 'inventory-t1' }
    const entityId = deriveObjectId(config, key)

    // tx1: create + install + share the storage unit.
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

    // tx2: mint the (transferable) owner cap to a plain address — here the signer.
    const capId = await mintAccessCap(client, config, {
      entity: entityId,
      owner: signer,
      transferable: true,
    })

    // tx3: owner enables the three owner-gated inventory actions.
    const enableTx = new Transaction()
    const entity = enableTx.object(entityId)
    const cap = enableTx.object(capId)
    enableAction(
      enableTx,
      config,
      entity,
      'bridge_in',
      [
        ownerRequirement(enableTx, config),
        bridgeInRequirement(enableTx, config, MODULE_ID, {}),
      ],
      cap,
    )
    enableAction(
      enableTx,
      config,
      entity,
      'withdraw',
      [
        ownerRequirement(enableTx, config),
        withdrawRequirement(enableTx, config, MODULE_ID, {}),
      ],
      cap,
    )
    enableAction(
      enableTx,
      config,
      entity,
      'deposit',
      [
        ownerRequirement(enableTx, config),
        depositRequirement(enableTx, config, MODULE_ID, {}),
      ],
      cap,
    )
    await expectSuccess(client, enableTx)

    // tx4: bridge_in 100 -> withdraw 20 -> deposit the Item back, one signer.
    const runTx = new Transaction()
    const e = runTx.object(entityId)
    const c = runTx.object(capId)

    const bridgeReqObj = interact(runTx, config, e, 'bridge_in', [])
    verifyProximity(runTx, config, bridgeReqObj, [])
    verifyOwner(runTx, config, bridgeReqObj, c)
    gameItemToChain(runTx, config, e, bridgeReqObj, {
      typeId: FUEL,
      quantity: 100n,
      volume: VOL,
    })
    completeRequest(runTx, config, e, bridgeReqObj)

    const wReq = interact(runTx, config, e, 'withdraw', [])
    verifyProximity(runTx, config, wReq, [])
    verifyOwner(runTx, config, wReq, c)
    const item = withdraw(runTx, config, e, wReq, {
      typeId: FUEL,
      quantity: 20n,
    })
    completeRequest(runTx, config, e, wReq)

    const dReq = interact(runTx, config, e, 'deposit', [])
    verifyProximity(runTx, config, dReq, [])
    verifyOwner(runTx, config, dReq, c)
    deposit(runTx, config, e, dReq, item)
    completeRequest(runTx, config, e, dReq)

    await expectSuccess(client, runTx)

    // Net balance: 100 in, 20 out, 20 back = 100.
    const balance = await readBalance(client, config, {
      entity: entityId,
      componentId: MODULE_ID,
      typeId: FUEL,
    })
    expect(balance).toBe(100n)
  })
})
