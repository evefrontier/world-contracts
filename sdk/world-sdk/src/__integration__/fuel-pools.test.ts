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
  installGenerator,
  installPowerGrid,
  operateGridRequirement,
  POWER_SCALE,
  type ProjectedPool,
  parseProjectedPools,
  projectedPools,
  setFuelBay,
  setGeneratorFuelType,
  siphon,
  siphonRequirement,
} from '../packages/power.js'
import {
  expectAbort,
  expectSuccess,
  loadLocalnetWorld,
  mintAccessCap,
  signer,
} from './helpers.js'

const HYDROGEN = 1n
const CRUDE = 2n
const HYDROGEN_BAY = 0xf1n
const CRUDE_BAY = 0xf2n
const EMERGENCY = 0xf3n
const UNITS = 100n
const SIPHONED = 40n * POWER_SCALE

const FUEL = {
  amount: UNITS,
  impulse: 90n * POWER_SCALE,
  containmentBurden: 14n * POWER_SCALE,
  volatility: 1n * POWER_SCALE,
  thermalInefficiency: 2n * POWER_SCALE,
}

describe('fuel pools (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('keeps one type per bay, pools by type, switches a generator and siphons a bay', async () => {
    const key = { id: 4990n, tenant: 'fuel-pools' }
    const entityId = deriveObjectId(config, key)

    const createTx = new Transaction()
    const [creation, claim] = entityNew(createTx, config, {
      inGameId: key.id,
      tenant: key.tenant,
    })
    verifyAdmin(createTx, config, claim)
    completeRequest(createTx, config, creation, claim)
    installPowerGrid(createTx, config, creation)
    for (const componentId of [HYDROGEN_BAY, CRUDE_BAY]) {
      installFuelBay(createTx, config, creation, {
        componentId,
        capacity: 1_000n,
        containmentRating: 10n * POWER_SCALE,
      })
    }
    installGenerator(createTx, config, creation, {
      componentId: EMERGENCY,
      fuelType: HYDROGEN,
      selectableFuelTypes: [HYDROGEN, CRUDE],
      maxOutputMw: 20n,
      impulseLimit: 100n * POWER_SCALE,
      volatilityLimit: 1n,
    })
    for (const action of ['set_fuel_bay', 'set_generator_fuel_type']) {
      enableAdminAction(createTx, config, creation, action, [
        operateGridRequirement(createTx, config),
      ])
    }
    enableAdminAction(createTx, config, creation, 'deposit_fuel', [
      depositFuelRequirement(createTx, config),
    ])
    enableAdminAction(createTx, config, creation, 'siphon', [
      siphonRequirement(createTx, config),
    ])
    shareEntity(createTx, config, creation)
    await expectSuccess(client, createTx)

    const capId = await mintAccessCap(client, config, {
      entity: entityId,
      owner: signer,
      transferable: true,
    })

    // Hydrogen into one bay, Crude into the other, both online.
    const fuelTx = new Transaction()
    addSponsors(fuelTx, config, [signer])
    const entity = fuelTx.object(entityId)
    const cap = fuelTx.object(capId)
    for (const [fuelBayId, fuelType] of [
      [HYDROGEN_BAY, HYDROGEN],
      [CRUDE_BAY, CRUDE],
    ]) {
      const deposit = interact(fuelTx, config, entity, 'deposit_fuel')
      depositFuel(fuelTx, config, entity, deposit, cap, {
        fuelBayId,
        fuelType,
        ...FUEL,
      })
      completeRequest(fuelTx, config, entity, deposit)
      const bay = interact(fuelTx, config, entity, 'set_fuel_bay')
      setFuelBay(fuelTx, config, entity, bay, cap, fuelBayId, true)
      completeRequest(fuelTx, config, entity, bay)
    }
    await expectSuccess(client, fuelTx)

    const full = await readPools(entityId)
    expect(full.get(HYDROGEN)).toMatchObject({
      quantity: UNITS * POWER_SCALE,
      impulse: FUEL.impulse,
      thermalInefficiency: FUEL.thermalInefficiency,
      runOutMs: null,
    })
    expect(full.get(CRUDE)?.quantity).toBe(UNITS * POWER_SCALE)

    // A bay holding Hydrogen refuses Crude.
    const mixTx = new Transaction()
    addSponsors(mixTx, config, [signer])
    const mixEntity = mixTx.object(entityId)
    const mix = interact(mixTx, config, mixEntity, 'deposit_fuel')
    depositFuel(mixTx, config, mixEntity, mix, mixTx.object(capId), {
      fuelBayId: HYDROGEN_BAY,
      fuelType: CRUDE,
      ...FUEL,
    })
    completeRequest(mixTx, config, mixEntity, mix)
    await expectAbort(client, mixTx, signer, /EFuelTypeMismatch/)

    // The owner switches the offline Emergency Generator to Crude.
    const switchTx = new Transaction()
    const switchEntity = switchTx.object(entityId)
    const switchRequest = interact(
      switchTx,
      config,
      switchEntity,
      'set_generator_fuel_type',
    )
    setGeneratorFuelType(
      switchTx,
      config,
      switchEntity,
      switchRequest,
      switchTx.object(capId),
      EMERGENCY,
      CRUDE,
    )
    completeRequest(switchTx, config, switchEntity, switchRequest)
    await expectSuccess(client, switchTx)

    // The admin siphons part of the Crude bay, then more than is left.
    const siphonTx = new Transaction()
    siphon(siphonTx, config, siphonTx.object(entityId), CRUDE_BAY, SIPHONED)
    await expectSuccess(client, siphonTx)
    const after = await readPools(entityId)
    expect(after.get(CRUDE)?.quantity).toBe(UNITS * POWER_SCALE - SIPHONED)
    expect(after.get(HYDROGEN)?.quantity).toBe(UNITS * POWER_SCALE)

    const shortTx = new Transaction()
    siphon(
      shortTx,
      config,
      shortTx.object(entityId),
      CRUDE_BAY,
      UNITS * POWER_SCALE,
    )
    await expectAbort(client, shortTx, signer, /EBayShort/)
  })

  async function readPools(
    entityId: string,
  ): Promise<Map<bigint, ProjectedPool>> {
    const tx = new Transaction()
    tx.setSender(signer)
    projectedPools(tx, config, tx.object(entityId))
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
    return new Map(
      parseProjectedPools(value.bcs).map((pool) => [pool.poolFuelType, pool]),
    )
  }
})
