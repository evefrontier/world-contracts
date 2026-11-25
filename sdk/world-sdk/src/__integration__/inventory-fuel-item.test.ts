import { bcs } from '@mysten/sui/bcs'
import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import {
  addSponsors,
  completeRequest,
  deriveObjectId,
  enableAdminAction,
  interact,
  ownerRequirement,
  verifyOwner,
} from '../packages/core.js'
import {
  bridgeInRequirement,
  createStorageUnit,
  depositFuelItem,
  gameItemToChain,
  withdraw,
  withdrawRequirement,
} from '../packages/inventory.js'
import { POWER_SCALE } from '../packages/power.js'
import { MASS_UNIT } from '../packages/variant.js'
import {
  bringInventoryOnline,
  FUEL_BAY_ID,
  INVENTORY_FUEL,
} from './bring-online.js'
import {
  expectSuccess,
  fuelVariant,
  fuelVariantKey,
  loadLocalnetWorld,
  mintAccessCap,
  readBalance,
  signer,
} from './helpers.js'

// Burn a fuel Item from the inventory into the grid's fuel bay: bridge fuel in,
// withdraw part of it as an Item, and deposit that Item into the bay with
// `depositFuelItem`, all in one owner-signed, sponsored transaction.
const MODULE_ID = 0x81n
const BRIDGED_KG = 50n
const BURNED_KG = 20n

const FuelItemDeposited = bcs.struct('FuelItemDeposited', {
  item_id: bcs.Address,
  key: bcs.struct('VariantKey', {
    tenant: bcs.string(),
    type_id: bcs.u64(),
    variant_id: bcs.u64(),
  }),
  quantity: bcs.u64(),
  entity_id: bcs.Address,
  fuel_bay_id: bcs.u64(),
})

describe('inventory fuel item (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('withdraws a fuel item and burns it into a fuel bay', async () => {
    const key = { id: 4650n, tenant: 'inventory-fuel' }
    const entityId = deriveObjectId(config, key)

    const createTx = new Transaction()
    createStorageUnit(createTx, config, {
      inGameId: key.id,
      tenant: key.tenant,
      componentId: MODULE_ID,
      typeId: 1n,
      name: 'Fuel Depot',
      // nano-m³: 1,000 m³, room for the test fuel at 1 m³ per kg.
      capacity: 1_000n * POWER_SCALE,
    })
    await expectSuccess(client, createTx)

    const capId = await mintAccessCap(client, config, {
      entity: entityId,
      owner: signer,
      transferable: true,
    })

    const enableTx = new Transaction()
    const enabled = enableTx.object(entityId)
    enableAdminAction(enableTx, config, enabled, 'bridge_in', [
      ownerRequirement(enableTx, config),
      bridgeInRequirement(enableTx, config, MODULE_ID, {}),
    ])
    enableAdminAction(enableTx, config, enabled, 'withdraw', [
      ownerRequirement(enableTx, config),
      withdrawRequirement(enableTx, config, MODULE_ID, {}),
    ])
    await expectSuccess(client, enableTx)
    // Installs the fuel bay and exposes `deposit_fuel`.
    await bringInventoryOnline(
      client,
      config,
      entityId,
      key.tenant,
      capId,
      MODULE_ID,
    )

    const fuelStats = { tenant: key.tenant, ...INVENTORY_FUEL }
    const fuel = await fuelVariant(client, config, fuelStats)
    const fuelKey = fuelVariantKey(fuelStats)

    const tx = new Transaction()
    addSponsors(tx, config, [signer])
    const e = tx.object(entityId)
    const c = tx.object(capId)

    const bridgeRequest = interact(tx, config, e, 'bridge_in')
    verifyOwner(tx, config, e, bridgeRequest, c)
    gameItemToChain(tx, config, e, bridgeRequest, {
      variant: fuel,
      quantity: BRIDGED_KG * MASS_UNIT,
    })
    completeRequest(tx, config, e, bridgeRequest)

    const withdrawRequest = interact(tx, config, e, 'withdraw')
    verifyOwner(tx, config, e, withdrawRequest, c)
    const item = withdraw(tx, config, e, withdrawRequest, {
      key: fuelKey,
      quantity: BURNED_KG * MASS_UNIT,
    })
    completeRequest(tx, config, e, withdrawRequest)

    const fuelRequest = interact(tx, config, e, 'deposit_fuel')
    depositFuelItem(tx, config, e, fuelRequest, c, {
      fuelBayId: FUEL_BAY_ID,
      item,
      variant: fuel,
    })
    completeRequest(tx, config, e, fuelRequest)

    const result = await expectSuccess(client, tx)
    const events = result.events ?? []
    const name = (eventType: string) => eventType.split('::').pop()
    expect(events.map((event) => name(event.eventType))).toContain('FuelAdded')
    const deposited = events.find(
      (event) => name(event.eventType) === 'FuelItemDeposited',
    )
    if (!deposited) throw new Error('no FuelItemDeposited event')
    const parsed = FuelItemDeposited.parse(deposited.bcs)
    expect(BigInt(parsed.quantity)).toBe(BURNED_KG * MASS_UNIT)
    expect(BigInt(parsed.fuel_bay_id)).toBe(FUEL_BAY_ID)
    expect(BigInt(parsed.key.variant_id)).toBe(fuelKey.variantId)

    const balance = await readBalance(client, config, {
      entity: entityId,
      componentId: MODULE_ID,
      key: fuelKey,
    })
    expect(balance).toBe((BRIDGED_KG - BURNED_KG) * MASS_UNIT)
  })
})
