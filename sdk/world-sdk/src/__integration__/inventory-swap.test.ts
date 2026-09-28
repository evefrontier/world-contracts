import { Transaction, type TransactionArgument } from '@mysten/sui/transactions'
import { normalizeSuiAddress } from '@mysten/sui/utils'
import { beforeAll, describe, expect, it } from 'vitest'
import {
  addSponsors,
  completeRequest,
  deriveObjectId,
  enableAction,
  interact,
  ownerRequirement,
  verifyDocking,
  verifyOwner,
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
  dockedProof,
  expectAbort,
  expectSponsored,
  expectSuccess,
  genesisAccount,
  loadLocalnetWorld,
  mintAccessCap,
  readBalance,
  signer,
} from './helpers.js'

// A merchant (admin) runs a trading post with a public FUEL -> LENS swap.
// PLAYER_A owns two ships: one docked at the trading post, one docked at another structure.
const MODULE_ID = 0x51n
const FUEL = 88834n
const LENS = 55n
const VOL = 2n
const TRADING_POST_TYPE = 1n
const SHIP_TYPE = 2n
const TENANT = 'inventory-t3'
// Stand-in dock for the other ship. Only the id matters to the proof.
const OTHER_DOCK = normalizeSuiAddress('0xe15e')

describe('ship docks at a trading post and swaps cargo (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  const tradingPostId = deriveObjectId(config, { id: 4400n, tenant: TENANT })
  const shipId = deriveObjectId(config, { id: 4401n, tenant: TENANT })
  const otherShipId = deriveObjectId(config, { id: 4402n, tenant: TENANT })

  const pilot = genesisAccount('PLAYER_A')
  const pilotAddr = pilot.toSuiAddress()
  let shipCapId: string
  let otherShipCapId: string

  beforeAll(async () => {
    // No ship module yet, so ships are storage units.
    const setupTx = new Transaction()
    for (const [inGameId, typeId, unitName] of [
      [4400n, TRADING_POST_TYPE, 'Trading Post'],
      [4401n, SHIP_TYPE, 'PLAYER_A Ship'],
      [4402n, SHIP_TYPE, 'Other Ship'],
    ] as const) {
      createStorageUnit(setupTx, config, {
        inGameId,
        tenant: TENANT,
        componentId: MODULE_ID,
        typeId,
        name: unitName,
        capacity: 1000n,
      })
    }
    await expectSuccess(client, setupTx)

    const merchantCapId = await mintAccessCap(client, config, {
      entity: tradingPostId,
      owner: signer,
      transferable: true,
    })
    shipCapId = await mintAccessCap(client, config, {
      entity: shipId,
      owner: pilotAddr,
      transferable: true,
    })
    otherShipCapId = await mintAccessCap(client, config, {
      entity: otherShipId,
      owner: pilotAddr,
      transferable: true,
    })

    // Merchant: owner-only restock, and a public swap gated only by the item rule.
    const merchantTx = new Transaction()
    const tradingStructure = merchantTx.object(tradingPostId)
    const merchantCap = merchantTx.object(merchantCapId)
    enableAction(
      merchantTx,
      config,
      tradingStructure,
      'bridge_in',
      [
        ownerRequirement(merchantTx, config),
        bridgeInRequirement(merchantTx, config, MODULE_ID, {}),
      ],
      merchantCap,
    )
    enableAction(
      merchantTx,
      config,
      tradingStructure,
      'swap',
      [
        depositRequirement(merchantTx, config, MODULE_ID, {
          typeId: FUEL,
          minQuantity: 1n,
          maxQuantity: 1n,
        }),
        withdrawRequirement(merchantTx, config, MODULE_ID, {
          typeId: LENS,
          minQuantity: 1n,
          maxQuantity: 1n,
        }),
      ],
      merchantCap,
    )
    await expectSuccess(client, merchantTx)

    // Pilot: owner-only bridge_in, withdraw and deposit on both ships.
    const pilotTx = new Transaction()
    for (const [entityId, capId] of [
      [shipId, shipCapId],
      [otherShipId, otherShipCapId],
    ] as const) {
      const entity = pilotTx.object(entityId)
      const cap = pilotTx.object(capId)
      for (const [action, rule] of [
        ['bridge_in', bridgeInRequirement(pilotTx, config, MODULE_ID, {})],
        ['withdraw', withdrawRequirement(pilotTx, config, MODULE_ID, {})],
        ['deposit', depositRequirement(pilotTx, config, MODULE_ID, {})],
      ] as const) {
        enableAction(
          pilotTx,
          config,
          entity,
          action,
          [ownerRequirement(pilotTx, config), rule],
          cap,
        )
      }
    }
    await expectSuccess(client, pilotTx, pilot)

    // Merchant stocks one lens.
    const stockTx = new Transaction()
    addSponsors(stockTx, config, [signer])
    const tradingPost = stockTx.object(tradingPostId)
    const stockRequest = interact(stockTx, config, tradingPost, 'bridge_in')
    verifyOwner(stockTx, config, stockRequest, stockTx.object(merchantCapId))
    gameItemToChain(stockTx, config, tradingPost, stockRequest, {
      typeId: LENS,
      quantity: 1n,
      volume: VOL,
    })
    completeRequest(stockTx, config, tradingPost, stockRequest)
    await expectSuccess(client, stockTx)

    // Pilot bridges one fuel onto each ship; bridging needs a sponsor, so the admin pays gas.
    const fuelTx = new Transaction()
    for (const [entityId, capId] of [
      [shipId, shipCapId],
      [otherShipId, otherShipCapId],
    ] as const) {
      const ship = fuelTx.object(entityId)
      const bridgeRequest = interact(fuelTx, config, ship, 'bridge_in')
      verifyOwner(fuelTx, config, bridgeRequest, fuelTx.object(capId))
      gameItemToChain(fuelTx, config, ship, bridgeRequest, {
        typeId: FUEL,
        quantity: 1n,
        volume: VOL,
      })
      completeRequest(fuelTx, config, ship, bridgeRequest)
    }
    await expectSponsored(client, fuelTx, pilot)
  }, 120_000)

  /** Withdraw one FUEL from a pilot ship. */
  function unload(
    tx: Transaction,
    shipId: string,
    capId: string,
  ): TransactionArgument {
    const ship = tx.object(shipId)
    const withdrawRequest = interact(tx, config, ship, 'withdraw')
    verifyOwner(tx, config, withdrawRequest, tx.object(capId))
    const fuel = withdraw(tx, config, ship, withdrawRequest, {
      typeId: FUEL,
      quantity: 1n,
    })
    completeRequest(tx, config, ship, withdrawRequest)
    return fuel
  }

  /** Swap `fuel` for a LENS at the trading post. */
  function swap(
    tx: Transaction,
    fuel: TransactionArgument,
  ): TransactionArgument {
    const tradingStructure = tx.object(tradingPostId)
    const swapRequest = interact(tx, config, tradingStructure, 'swap')
    deposit(tx, config, tradingStructure, swapRequest, fuel)
    const lens = withdraw(tx, config, tradingStructure, swapRequest, {
      typeId: LENS,
      quantity: 1n,
    })
    completeRequest(tx, config, tradingStructure, swapRequest)
    return lens
  }

  /** Deposit the swapped `lens` onto the docked ship. */
  function depositLens(tx: Transaction, lens: TransactionArgument): void {
    const ship = tx.object(shipId)
    const depositRequest = interact(tx, config, ship, 'deposit')
    verifyOwner(tx, config, depositRequest, tx.object(shipCapId))
    deposit(tx, config, ship, depositRequest, lens)
    completeRequest(tx, config, ship, depositRequest)
  }

  const dock = (tx: Transaction, ship: string, target: string) =>
    verifyDocking(tx, config, dockedProof(config, ship, target, pilotAddr))

  it('rejects a swap with no docking', async () => {
    // withdraw and deposit check the docking inline, so the first unload aborts.
    const tx = new Transaction()
    depositLens(tx, swap(tx, unload(tx, shipId, shipCapId)))
    await expectAbort(client, tx, pilotAddr, /ENoDocking/)
  })

  it('rejects a ship docked at the other dock', async () => {
    const tx = new Transaction()
    dock(tx, shipId, OTHER_DOCK)
    depositLens(tx, swap(tx, unload(tx, shipId, shipCapId)))
    await expectAbort(client, tx, pilotAddr, /ENotDocked/)
  })

  it('rejects a second docking proof in one transaction', async () => {
    // One docking per transaction: the other ship's proof can't be mixed with the docked ship's.
    const tx = new Transaction()
    dock(tx, otherShipId, OTHER_DOCK)
    dock(tx, shipId, tradingPostId)
    depositLens(tx, swap(tx, unload(tx, otherShipId, otherShipCapId)))
    await expectAbort(client, tx, pilotAddr, /EAlreadyDocked/)
  })

  it('rejects cargo from a ship that is not the docked one', async () => {
    // The other ship is not part of the docking, so its unload aborts.
    const tx = new Transaction()
    dock(tx, shipId, tradingPostId)
    depositLens(tx, swap(tx, unload(tx, otherShipId, otherShipCapId)))
    await expectAbort(client, tx, pilotAddr, /ENotDocked/)
  })

  it("swaps fuel from the pilot's docked ship for the merchant's lens", async () => {
    // One docking proof covers every withdraw and deposit: ship to trading post to ship.
    // The pilot holds no merchant cap; the public swap needs none.
    const tx = new Transaction()
    dock(tx, shipId, tradingPostId)
    depositLens(tx, swap(tx, unload(tx, shipId, shipCapId)))
    await expectSuccess(client, tx, pilot)

    const itemBalance = (entity: string, typeId: bigint) =>
      readBalance(client, config, { entity, componentId: MODULE_ID, typeId })

    expect(await itemBalance(tradingPostId, FUEL)).toBe(1n)
    expect(await itemBalance(tradingPostId, LENS)).toBe(0n)
    expect(await itemBalance(shipId, LENS)).toBe(1n)
    expect(await itemBalance(shipId, FUEL)).toBe(0n)
    expect(await itemBalance(otherShipId, FUEL)).toBe(1n)
  })
})
