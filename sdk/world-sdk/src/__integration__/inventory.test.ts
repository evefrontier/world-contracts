import { fileURLToPath } from 'node:url'
import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import { createWorldClient } from '../client.js'
import { loadWorldConfig } from '../config/load.js'
import {
  callerRequirement,
  completeRequest,
  deriveObjectId,
  enableAction,
  interact,
  mintAccess,
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
  capObjectId,
  expectSuccess,
  readBalance,
  requirePackage,
  signer,
} from './helpers.js'

// Exercise the inventory bindings in isolation. Create a storage-unit entity,
// mint the owner cap to a plain address, enable owner deposit/withdraw/bridge
// actions, then round-trip a balance: bridge_in seeds it, withdraw yields an Item,
// deposit puts it back.
const MANIFEST = fileURLToPath(
  new URL('../../../../deployments/localnet/world.json', import.meta.url),
)

const UNIT = 'SU-01'
const FUEL = 88834n
const VOL = 2n

describe('inventory owner round-trip (localnet)', () => {
  const config = loadWorldConfig(MANIFEST)
  const client = createWorldClient({ config })

  it('bridges in, withdraws, and deposits back on the main inventory', async () => {
    const key = { id: 4200n, tenant: 'inventory-t1' }
    const entityId = deriveObjectId(config, key)

    // tx1: create + install + share the storage unit.
    const createTx = new Transaction()
    createStorageUnit(createTx, config, {
      inGameId: key.id,
      tenant: key.tenant,
      name: UNIT,
      mainCapacity: 1000n,
      ephemeralCapacity: 100n,
    })
    await expectSuccess(client, createTx)

    // tx2: mint the (transferable) owner cap to a plain address — here the signer.
    const mintTx = new Transaction()
    mintAccess(mintTx, config, {
      entity: entityId,
      owner: signer,
      transferable: true,
    })
    const minted = await expectSuccess(client, mintTx, {
      showObjectChanges: true,
    })
    const capId = capObjectId(minted, requirePackage(config, 'core'))

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
        bridgeInRequirement(enableTx, config, UNIT, { ephemeral: false }),
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
        withdrawRequirement(enableTx, config, UNIT, { ephemeral: false }),
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
        depositRequirement(enableTx, config, UNIT, { ephemeral: false }),
      ],
      cap,
    )
    await expectSuccess(client, enableTx)

    // tx4: bridge_in 100 -> withdraw 20 -> deposit the Item back, one signer.
    const runTx = new Transaction()
    const e = runTx.object(entityId)
    const c = runTx.object(capId)

    const bridgeReqObj = interact(runTx, config, e, 'bridge_in')
    verifyProximity(runTx, config, bridgeReqObj)
    verifyCaller(runTx, config, bridgeReqObj, c)
    gameItemToChain(runTx, config, e, bridgeReqObj, {
      typeId: FUEL,
      quantity: 100n,
      volume: VOL,
    })
    completeRequest(runTx, config, e, bridgeReqObj)

    const wReq = interact(runTx, config, e, 'withdraw')
    verifyProximity(runTx, config, wReq)
    verifyCaller(runTx, config, wReq, c)
    const item = withdraw(runTx, config, e, wReq, {
      typeId: FUEL,
      quantity: 20n,
    })
    completeRequest(runTx, config, e, wReq)

    const dReq = interact(runTx, config, e, 'deposit')
    verifyProximity(runTx, config, dReq)
    verifyCaller(runTx, config, dReq, c)
    deposit(runTx, config, e, dReq, item)
    completeRequest(runTx, config, e, dReq)

    await expectSuccess(client, runTx)

    // Net main balance: 100 in, 20 out, 20 back = 100.
    const main = await readBalance(client, config, {
      entity: entityId,
      name: UNIT,
      authorizedId: entityId,
      typeId: FUEL,
    })
    expect(main).toBe(100n)
  })
})
