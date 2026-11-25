import { Transaction, type TransactionArgument } from '@mysten/sui/transactions'
import { beforeAll, describe, expect, it } from 'vitest'
import {
  addSponsors,
  completeRequest,
  deriveObjectId,
  dock,
  enableAction,
  interact,
  ownerRequirement,
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
import { bringInventoryOnline } from './bring-online.js'
import {
  expectAbort,
  expectSponsored,
  expectSuccess,
  genesisAccount,
  itemVariant,
  loadLocalnetWorld,
  mintAccessCap,
  readBalance,
  signer,
} from './helpers.js'

// A merchant (admin) runs a trading post with a public FUEL -> LENS swap. Its rules
// pin the variant on both sides: a type-only withdraw rule would let the pilot
// pick any LENS variant in stock, including the better PRIZE one.
// PLAYER_A owns two ships: one docked at the trading post, the other not.
const MODULE_ID = 0x51n
const FUEL = 88834n
const LENS = 55n
const VOL = 2n
const TRADING_POST_TYPE = 1n
const SHIP_TYPE = 2n
const TENANT = 'inventory-t3'
/** The plain variant, the only one the swap trades. */
const PLAIN = 0n
/** A better LENS variant the merchant also stocks but does not swap. */
const PRIZE = 7n
/** Key of the `variantId` stack of `typeId` in `TENANT`. */
const itemKey = (typeId: bigint, variantId = PLAIN) => ({
  tenant: TENANT,
  typeId,
  variantId,
})

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
          variantId: PLAIN,
          minQuantity: 1n,
          maxQuantity: 1n,
        }),
        withdrawRequirement(merchantTx, config, MODULE_ID, {
          typeId: LENS,
          variantId: PLAIN,
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
      enableAction(
        pilotTx,
        config,
        entity,
        'bridge_in',
        [
          ownerRequirement(pilotTx, config),
          bridgeInRequirement(pilotTx, config, MODULE_ID, {}),
        ],
        cap,
      )
      enableAction(
        pilotTx,
        config,
        entity,
        'withdraw',
        [
          ownerRequirement(pilotTx, config),
          withdrawRequirement(pilotTx, config, MODULE_ID, {}),
        ],
        cap,
      )
      enableAction(
        pilotTx,
        config,
        entity,
        'deposit',
        [
          ownerRequirement(pilotTx, config),
          depositRequirement(pilotTx, config, MODULE_ID, {}),
        ],
        cap,
      )
    }
    await expectSuccess(client, pilotTx, pilot)

    await bringInventoryOnline(
      client,
      config,
      tradingPostId,
      TENANT,
      merchantCapId,
      MODULE_ID,
    )
    await bringInventoryOnline(
      client,
      config,
      shipId,
      TENANT,
      shipCapId,
      MODULE_ID,
      pilot,
    )
    await bringInventoryOnline(
      client,
      config,
      otherShipId,
      TENANT,
      otherShipCapId,
      MODULE_ID,
      pilot,
    )

    const lensVariant = await itemVariant(client, config, {
      tenant: TENANT,
      typeId: LENS,
      unitVolume: VOL,
    })
    const prizeLensVariant = await itemVariant(client, config, {
      tenant: TENANT,
      typeId: LENS,
      variantId: PRIZE,
      unitVolume: VOL,
    })
    const fuelItemVariant = await itemVariant(client, config, {
      tenant: TENANT,
      typeId: FUEL,
      unitVolume: VOL,
    })

    // Merchant stocks one plain lens and one prize lens.
    const stockTx = new Transaction()
    addSponsors(stockTx, config, [signer])
    const tradingPost = stockTx.object(tradingPostId)
    const stockRequest = interact(stockTx, config, tradingPost, 'bridge_in')
    verifyOwner(
      stockTx,
      config,
      tradingPost,
      stockRequest,
      stockTx.object(merchantCapId),
    )
    gameItemToChain(stockTx, config, tradingPost, stockRequest, {
      variant: lensVariant,
      quantity: 1n,
    })
    completeRequest(stockTx, config, tradingPost, stockRequest)
    const prizeRequest = interact(stockTx, config, tradingPost, 'bridge_in')
    verifyOwner(
      stockTx,
      config,
      tradingPost,
      prizeRequest,
      stockTx.object(merchantCapId),
    )
    gameItemToChain(stockTx, config, tradingPost, prizeRequest, {
      variant: prizeLensVariant,
      quantity: 1n,
    })
    completeRequest(stockTx, config, tradingPost, prizeRequest)
    await expectSuccess(client, stockTx)

    // Pilot bridges one fuel onto each ship; bridging needs a sponsor, so the admin pays gas.
    const fuelTx = new Transaction()
    for (const [entityId, capId] of [
      [shipId, shipCapId],
      [otherShipId, otherShipCapId],
    ] as const) {
      const ship = fuelTx.object(entityId)
      const bridgeRequest = interact(fuelTx, config, ship, 'bridge_in')
      verifyOwner(fuelTx, config, ship, bridgeRequest, fuelTx.object(capId))
      gameItemToChain(fuelTx, config, ship, bridgeRequest, {
        variant: fuelItemVariant,
        quantity: 1n,
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
    verifyOwner(tx, config, ship, withdrawRequest, tx.object(capId))
    const fuel = withdraw(tx, config, ship, withdrawRequest, {
      key: itemKey(FUEL),
      quantity: 1n,
    })
    completeRequest(tx, config, ship, withdrawRequest)
    return fuel
  }

  /** Swap `fuel` for a LENS of `lensVariant` at the trading post. */
  function swap(
    tx: Transaction,
    fuel: TransactionArgument,
    lensVariant = PLAIN,
  ): TransactionArgument {
    const tradingStructure = tx.object(tradingPostId)
    const swapRequest = interact(tx, config, tradingStructure, 'swap')
    deposit(tx, config, tradingStructure, swapRequest, fuel)
    const lens = withdraw(tx, config, tradingStructure, swapRequest, {
      key: itemKey(LENS, lensVariant),
      quantity: 1n,
    })
    completeRequest(tx, config, tradingStructure, swapRequest)
    return lens
  }

  /** Deposit the swapped `lens` onto the docked ship. */
  function depositLens(tx: Transaction, lens: TransactionArgument): void {
    const ship = tx.object(shipId)
    const depositRequest = interact(tx, config, ship, 'deposit')
    verifyOwner(tx, config, ship, depositRequest, tx.object(shipCapId))
    deposit(tx, config, ship, depositRequest, lens)
    completeRequest(tx, config, ship, depositRequest)
  }

  /** Admin docks `chaser` at `target`, on both entities. Docking persists on the entities. */
  const adminDock = async (target: string, chaser: string) => {
    const tx = new Transaction()
    dock(tx, config, tx.object(target), tx.object(chaser))
    await expectSuccess(client, tx)
  }

  // Docking is entity state, not a per-transaction proof, so these tests run in
  // order and each builds on the docking left by the one before.

  it('rejects a swap with no docking', async () => {
    // The ship can unload, but nothing is docked at the post, so the fuel deposit aborts.
    const tx = new Transaction()
    depositLens(tx, swap(tx, unload(tx, shipId, shipCapId)))
    await expectAbort(client, tx, pilotAddr, /ENotDocked/)
  })

  it('rejects a ship docked somewhere else', async () => {
    // The ship is docked with the other ship, but nothing is docked at the trading post.
    await adminDock(otherShipId, shipId)
    const tx = new Transaction()
    depositLens(tx, swap(tx, unload(tx, shipId, shipCapId)))
    await expectAbort(client, tx, pilotAddr, /ENotDocked/)
  })

  it('rejects cargo from a ship that is not docked at the trading post', async () => {
    // Dock the ship at the trading post; both sides record it, so fuel and the lens can each move.
    await adminDock(tradingPostId, shipId)
    // The other ship can unload, but it isn't docked at the trading post.
    const tx = new Transaction()
    depositLens(tx, swap(tx, unload(tx, otherShipId, otherShipCapId)))
    await expectAbort(client, tx, pilotAddr, /EWrongSource/)
  })

  it('rejects a swap for a lens variant the rule does not name', async () => {
    // Docked (previous test), but the swap's withdraw rule is pinned to the plain lens.
    const tx = new Transaction()
    depositLens(tx, swap(tx, unload(tx, shipId, shipCapId), PRIZE))
    await expectAbort(client, tx, pilotAddr, /EItemVariantNotAllowed/)
  })

  it("swaps fuel from the pilot's docked ship for the merchant's lens", async () => {
    // The ship is docked at the trading post (previous test), recorded on both, which covers
    // every withdraw and deposit: ship to trading post to ship.
    // The pilot holds no merchant cap; the public swap needs none.
    const tx = new Transaction()
    depositLens(tx, swap(tx, unload(tx, shipId, shipCapId)))
    await expectSuccess(client, tx, pilot)

    const itemBalance = (entity: string, typeId: bigint) =>
      readBalance(client, config, {
        entity,
        componentId: MODULE_ID,
        key: itemKey(typeId),
      })

    expect(await itemBalance(tradingPostId, FUEL)).toBe(1n)
    expect(await itemBalance(tradingPostId, LENS)).toBe(0n)
    const prizeLeft = await readBalance(client, config, {
      entity: tradingPostId,
      componentId: MODULE_ID,
      key: itemKey(LENS, PRIZE),
    })
    expect(prizeLeft).toBe(1n)
    expect(await itemBalance(shipId, LENS)).toBe(1n)
    expect(await itemBalance(shipId, FUEL)).toBe(0n)
    expect(await itemBalance(otherShipId, FUEL)).toBe(1n)
  })
})
