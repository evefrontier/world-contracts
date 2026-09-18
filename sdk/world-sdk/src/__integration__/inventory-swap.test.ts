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

// A owns entity1 (offers LENS). B owns entity2 (pays FUEL).
// B withdraws FUEL, swaps it for LENS on entity1, deposits LENS into entity2.
const MODULE_ID = 0x51n
const FUEL = 88834n
const LENS = 55n
const VOL = 2n

describe('inventory swap across two entities (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('swaps a fuel for a lens between two owner-gated inventories', async () => {
    const entity1Key = { id: 4400n, tenant: 'inventory-t3' }
    const entity1Id = deriveObjectId(config, entity1Key)
    const entity2Key = { id: 4401n, tenant: 'inventory-t3' }
    const entity2Id = deriveObjectId(config, entity2Key)

    // A owns entity1, B owns entity2 — both plain addresses here (the signer
    // stands in for both; access control is what's under test, not identity).
    const setupTx = new Transaction()
    createStorageUnit(setupTx, config, {
      inGameId: entity1Key.id,
      tenant: entity1Key.tenant,
      componentId: MODULE_ID,
      typeId: 1n,
      name: 'SU-03',
      capacity: 1000n,
    })
    createStorageUnit(setupTx, config, {
      inGameId: entity2Key.id,
      tenant: entity2Key.tenant,
      componentId: MODULE_ID,
      typeId: 1n,
      name: 'SU-04',
      capacity: 1000n,
    })
    await expectSuccess(client, setupTx)

    const ownerACapId = await mintAccessCap(client, config, {
      entity: entity1Id,
      owner: signer,
      transferable: true,
    })
    const ownerBCapId = await mintAccessCap(client, config, {
      entity: entity2Id,
      owner: signer,
      transferable: true,
    })

    // Each owner enables their own owner-gated bridge_in/withdraw/deposit.
    const enableTx = new Transaction()
    for (const [entityId, capId] of [
      [entity1Id, ownerACapId],
      [entity2Id, ownerBCapId],
    ] as const) {
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
    }
    // A configures a public swap on entity1: hand over one fuel, receive the
    // lens. No owner/caller gate - satisfying the item rule is the only gate.
    enableAction(
      enableTx,
      config,
      enableTx.object(entity1Id),
      'swap',
      [
        depositRequirement(enableTx, config, MODULE_ID, {
          typeId: FUEL,
          minQuantity: 1n,
          maxQuantity: 1n,
        }),
        withdrawRequirement(enableTx, config, MODULE_ID, {
          typeId: LENS,
          minQuantity: 1n,
          maxQuantity: 1n,
        }),
      ],
      enableTx.object(ownerACapId),
    )
    await expectSuccess(client, enableTx)

    // A bridges a lens onto entity1 (owner-only).
    const stockTx = new Transaction()
    const se = stockTx.object(entity1Id)
    const stockReq = interact(stockTx, config, se, 'bridge_in', [])
    verifyProximity(stockTx, config, stockReq, [])
    verifyOwner(stockTx, config, stockReq, stockTx.object(ownerACapId))
    gameItemToChain(stockTx, config, se, stockReq, {
      typeId: LENS,
      quantity: 1n,
      volume: VOL,
    })
    completeRequest(stockTx, config, se, stockReq)
    await expectSuccess(client, stockTx)

    // B bridges a fuel onto entity2 (owner-only, their own creation).
    const bridgeBTx = new Transaction()
    const be = bridgeBTx.object(entity2Id)
    const bridgeBReq = interact(bridgeBTx, config, be, 'bridge_in', [])
    verifyProximity(bridgeBTx, config, bridgeBReq, [])
    verifyOwner(bridgeBTx, config, bridgeBReq, bridgeBTx.object(ownerBCapId))
    gameItemToChain(bridgeBTx, config, be, bridgeBReq, {
      typeId: FUEL,
      quantity: 1n,
      volume: VOL,
    })
    completeRequest(bridgeBTx, config, be, bridgeBReq)
    await expectSuccess(client, bridgeBTx)

    // B flies to A and, in one signed transaction: withdraws the fuel from
    // entity2, swaps it for the lens on entity1, then deposits the lens into
    // entity2. Nothing is left over.
    const runTx = new Transaction()
    const e2 = runTx.object(entity2Id)
    const capB = runTx.object(ownerBCapId)

    const wReq = interact(runTx, config, e2, 'withdraw', [])
    verifyProximity(runTx, config, wReq, [])
    verifyOwner(runTx, config, wReq, capB)
    const fuel = withdraw(runTx, config, e2, wReq, {
      typeId: FUEL,
      quantity: 1n,
    })
    completeRequest(runTx, config, e2, wReq)

    const e1 = runTx.object(entity1Id)
    const swapReq = interact(runTx, config, e1, 'swap', [])
    verifyProximity(runTx, config, swapReq, [])
    deposit(runTx, config, e1, swapReq, fuel)
    const lens = withdraw(runTx, config, e1, swapReq, {
      typeId: LENS,
      quantity: 1n,
    })
    completeRequest(runTx, config, e1, swapReq)

    const dReq = interact(runTx, config, e2, 'deposit', [])
    verifyProximity(runTx, config, dReq, [])
    verifyOwner(runTx, config, dReq, capB)
    deposit(runTx, config, e2, dReq, lens)
    completeRequest(runTx, config, e2, dReq)

    await expectSuccess(client, runTx)

    const read = (entity: string, typeId: bigint) =>
      readBalance(client, config, { entity, componentId: MODULE_ID, typeId })

    expect(await read(entity1Id, FUEL)).toBe(1n) // fuel now on entity1
    expect(await read(entity1Id, LENS)).toBe(0n) // lens left entity1
    expect(await read(entity2Id, LENS)).toBe(1n) // lens now on entity2
    expect(await read(entity2Id, FUEL)).toBe(0n) // fuel left entity2
  })
})
