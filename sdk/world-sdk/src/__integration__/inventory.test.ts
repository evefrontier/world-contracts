import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import {
  callerRequirement,
  completeRequest,
  deriveObjectId,
  enableAction,
  interact,
  verifyCaller,
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
  readHasSingleton,
  signer,
} from './helpers.js'

// Exercise the inventory bindings in isolation. Create a storage-unit entity,
// mint the owner cap to a plain address, enable owner deposit/withdraw/bridge
// actions, then round-trip a fungible balance and a singleton Item.
const MODULE_ID = 0x51n
const UNIT = 'SU-01'
const FUEL = 88834n
const BLUEPRINT = 77n
const VOL = 2n
const BLUEPRINT_VOL = 500n
const BLUEPRINT_ITEM = 1n

describe('inventory owner round-trip (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  async function setupOwnerUnit(key: { id: bigint; tenant: string }) {
    const entityId = deriveObjectId(config, key)

    // tx1: create + install + share the storage unit.
    const createTx = new Transaction()
    createStorageUnit(createTx, config, {
      inGameId: key.id,
      tenant: key.tenant,
      moduleId: MODULE_ID,
      name: UNIT,
      mainCapacity: 1000n,
      ephemeralCapacity: 100n,
    })
    await expectSuccess(client, createTx)

    // tx2: mint the (transferable) owner cap to a plain address — here the signer.
    const capId = await mintAccessCap(client, config, {
      entity: entityId,
      owner: signer,
      transferable: true,
    })

    // tx3: owner enables the three main-inventory actions.
    const enableTx = new Transaction()
    const entity = enableTx.object(entityId)
    const cap = enableTx.object(capId)
    enableAction(
      enableTx,
      config,
      entity,
      'bridge_in',
      [
        callerRequirement(enableTx, config),
        bridgeInRequirement(enableTx, config, MODULE_ID, { ephemeral: false }),
      ],
      cap,
    )
    enableAction(
      enableTx,
      config,
      entity,
      'withdraw',
      [
        callerRequirement(enableTx, config),
        withdrawRequirement(enableTx, config, MODULE_ID, { ephemeral: false }),
      ],
      cap,
    )
    enableAction(
      enableTx,
      config,
      entity,
      'deposit',
      [
        callerRequirement(enableTx, config),
        depositRequirement(enableTx, config, MODULE_ID, { ephemeral: false }),
      ],
      cap,
    )
    await expectSuccess(client, enableTx)

    return { entityId, capId }
  }

  it('bridges in, withdraws, and deposits back on the main inventory', async () => {
    const { entityId, capId } = await setupOwnerUnit({
      id: 4200n,
      tenant: 'inventory-t1',
    })

    const runTx = new Transaction()
    const e = runTx.object(entityId)
    const c = runTx.object(capId)

    const bridgeReqObj = interact(runTx, config, e, 'bridge_in', [])
    verifyProximity(runTx, config, bridgeReqObj, [])
    verifyCaller(runTx, config, bridgeReqObj, c)
    gameItemToChain(runTx, config, e, bridgeReqObj, {
      typeId: FUEL,
      quantity: 100n,
      volume: VOL,
    })
    completeRequest(runTx, config, e, bridgeReqObj)

    const wReq = interact(runTx, config, e, 'withdraw', [])
    verifyProximity(runTx, config, wReq, [])
    verifyCaller(runTx, config, wReq, c)
    const item = withdraw(runTx, config, e, wReq, {
      typeId: FUEL,
      quantity: 20n,
    })
    completeRequest(runTx, config, e, wReq)

    const dReq = interact(runTx, config, e, 'deposit', [])
    verifyProximity(runTx, config, dReq, [])
    verifyCaller(runTx, config, dReq, c)
    deposit(runTx, config, e, dReq, item)
    completeRequest(runTx, config, e, dReq)

    await expectSuccess(client, runTx)

    const main = await readBalance(client, config, {
      entity: entityId,
      moduleId: MODULE_ID,
      authorizedId: entityId,
      typeId: FUEL,
    })
    expect(main).toBe(100n)
  })

  it('bridges in, withdraws, and deposits a singleton on the main inventory', async () => {
    const { entityId, capId } = await setupOwnerUnit({
      id: 4210n,
      tenant: 'inventory-t1',
    })

    const runTx = new Transaction()
    const e = runTx.object(entityId)
    const c = runTx.object(capId)

    const bridgeReqObj = interact(runTx, config, e, 'bridge_in', [])
    verifyProximity(runTx, config, bridgeReqObj, [])
    verifyCaller(runTx, config, bridgeReqObj, c)
    gameItemToChain(runTx, config, e, bridgeReqObj, {
      typeId: BLUEPRINT,
      itemId: BLUEPRINT_ITEM,
      volume: BLUEPRINT_VOL,
    })
    completeRequest(runTx, config, e, bridgeReqObj)

    const wReq = interact(runTx, config, e, 'withdraw', [])
    verifyProximity(runTx, config, wReq, [])
    verifyCaller(runTx, config, wReq, c)
    const item = withdraw(runTx, config, e, wReq, {
      typeId: BLUEPRINT,
      itemId: BLUEPRINT_ITEM,
    })
    completeRequest(runTx, config, e, wReq)

    const dReq = interact(runTx, config, e, 'deposit', [])
    verifyProximity(runTx, config, dReq, [])
    verifyCaller(runTx, config, dReq, c)
    deposit(runTx, config, e, dReq, item)
    completeRequest(runTx, config, e, dReq)

    await expectSuccess(client, runTx)

    const present = await readHasSingleton(client, config, {
      entity: entityId,
      moduleId: MODULE_ID,
      authorizedId: entityId,
      itemId: BLUEPRINT_ITEM,
    })
    expect(present).toBe(true)

    const asFungible = await readBalance(client, config, {
      entity: entityId,
      moduleId: MODULE_ID,
      authorizedId: entityId,
      typeId: BLUEPRINT,
    })
    expect(asFungible).toBe(0n)
  })
})
