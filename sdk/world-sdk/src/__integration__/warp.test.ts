import { bcs } from '@mysten/sui/bcs'
import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import {
  addSponsors,
  completeRequest,
  deriveObjectId,
  enableAdminAction,
  entityNew,
  interact,
  shareEntity,
  verifyAdmin,
} from '../packages/core.js'
import {
  depositFuel,
  depositFuelRequirement,
  installFuelBay,
  installPowerGrid,
  operateGridRequirement,
  POWER_SCALE,
  projectedFuel,
  setFuelBay,
  withdrawFuel,
  withdrawFuelRequirement,
} from '../packages/power.js'
import {
  expectAbort,
  expectSuccess,
  loadLocalnetWorld,
  mintAccessCap,
  signer,
} from './helpers.js'

const BAY_ID = 0xe1n
const UNITS = 100n
// The overview's warp: 0.5 units/s for 20 s.
const WARP_COST = 10n * POWER_SCALE

describe('warp fuel (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('takes a warp cost from the online bays, all or nothing', async () => {
    const key = { id: 4970n, tenant: 'warp' }
    const entityId = deriveObjectId(config, key)

    const createTx = new Transaction()
    const [creation, claim] = entityNew(createTx, config, {
      inGameId: key.id,
      tenant: key.tenant,
    })
    verifyAdmin(createTx, config, claim)
    completeRequest(createTx, config, creation, claim)
    installPowerGrid(createTx, config, creation)
    installFuelBay(createTx, config, creation, {
      componentId: BAY_ID,
      capacity: 1_000n,
    })
    enableAdminAction(createTx, config, creation, 'set_fuel_bay', [
      operateGridRequirement(createTx, config),
    ])
    enableAdminAction(createTx, config, creation, 'deposit_fuel', [
      depositFuelRequirement(createTx, config),
    ])
    enableAdminAction(createTx, config, creation, 'withdraw_fuel', [
      withdrawFuelRequirement(createTx, config),
    ])
    shareEntity(createTx, config, creation)
    await expectSuccess(client, createTx)

    const capId = await mintAccessCap(client, config, {
      entity: entityId,
      owner: signer,
      transferable: true,
    })
    const fuelTx = new Transaction()
    addSponsors(fuelTx, config, [signer])
    const entity = fuelTx.object(entityId)
    const cap = fuelTx.object(capId)
    const fuel = interact(fuelTx, config, entity, 'deposit_fuel')
    depositFuel(fuelTx, config, entity, fuel, cap, {
      fuelBayId: BAY_ID,
      fuelType: 1n,
      amount: UNITS,
      impulse: 90n * POWER_SCALE,
      containmentBurden: 14n * POWER_SCALE,
      volatility: 1n * POWER_SCALE,
    })
    completeRequest(fuelTx, config, entity, fuel)
    const bay = interact(fuelTx, config, entity, 'set_fuel_bay')
    setFuelBay(fuelTx, config, entity, bay, cap, BAY_ID, true)
    completeRequest(fuelTx, config, entity, bay)
    await expectSuccess(client, fuelTx)

    const warpTx = new Transaction()
    withdrawFuel(warpTx, config, warpTx.object(entityId), WARP_COST)
    await expectSuccess(client, warpTx)
    const left = UNITS * POWER_SCALE - WARP_COST
    expect(await readFuel(entityId)).toBe(left)

    // More than the bays hold: no warp, and nothing is taken.
    const shortTx = new Transaction()
    withdrawFuel(shortTx, config, shortTx.object(entityId), left + 1n)
    await expectAbort(client, shortTx, signer, /EFuelShort/)
    expect(await readFuel(entityId)).toBe(left)
  })

  async function readFuel(entityId: string): Promise<bigint> {
    const tx = new Transaction()
    tx.setSender(signer)
    projectedFuel(tx, config, tx.object(entityId))
    const res = await client.simulateTransaction({
      transaction: tx,
      include: { commandResults: true },
    })
    if (res.FailedTransaction) {
      throw new Error(
        res.FailedTransaction.status.error?.message ?? 'read failed',
      )
    }
    const value = res.commandResults?.at(-1)?.returnValues[0]
    if (!value) throw new Error('read returned no value')
    return BigInt(bcs.u64().parse(value.bcs))
  }
})
