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
import { installGenericModule } from '../packages/generic-module.js'
import {
  type DrawKind,
  depositFuel,
  depositFuelRequirement,
  generatorStatus,
  installFuelBay,
  installGenerator,
  installPowerGrid,
  moduleDraw,
  moduleStatus,
  operateGridRequirement,
  POWER_SCALE,
  parsePowerStatus,
  parseProjectedBays,
  parseProjectedPools,
  parseProjectedSnapshot,
  projectedBays,
  projectedPools,
  projectedSnapshot,
  projectedStatus,
  setDesiredState,
  setFuelBay,
  setGenerator,
  setPowerGrid,
} from '../packages/power.js'
import { MASS_UNIT } from '../packages/variant.js'
import {
  expectSuccess,
  fuelVariant,
  loadLocalnetWorld,
  mintAccessCap,
  seatShell,
  signer,
} from './helpers.js'

const HYDROGEN = 1n
const CRUDE = 2n
const MAIN = 0xd0n
const SPARE = 0xd1n
const HYDROGEN_BAY = 0xd2n
const CRUDE_BAY = 0xd3n
const EMPTY_BAY = 0xd4n
const MODULES: Record<string, [bigint, bigint, DrawKind, boolean]> = {
  firm: [0xdan, 20n * POWER_SCALE, 'firm', true],
  elastic: [0xdbn, 30n * POWER_SCALE, 'elastic', true],
  off: [0xdcn, 10n * POWER_SCALE, 'firm', false],
}

const UNITS = 100n
const FUEL = {
  impulse: 90n * POWER_SCALE,
  containmentBurden: 14n * POWER_SCALE,
  volatility: 1n * POWER_SCALE,
  thermalInefficiency: 2n * POWER_SCALE,
}

describe('power snapshot (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('decodes a snapshot that equals every single reader at the same clock', async () => {
    const key = { id: 4995n, tenant: 'power-snapshot' }
    const entityId = deriveObjectId(config, key)

    const createTx = new Transaction()
    const [creation, claim] = entityNew(createTx, config, {
      inGameId: key.id,
      tenant: key.tenant,
    })
    verifyAdmin(createTx, config, claim)
    completeRequest(createTx, config, creation, claim)
    installPowerGrid(createTx, config, creation)
    seatShell(createTx, config, creation)
    for (const componentId of [MAIN, SPARE]) {
      installGenerator(createTx, config, creation, {
        componentId,
        fuelType: componentId === MAIN ? HYDROGEN : CRUDE,
        selectableFuelTypes: [HYDROGEN, CRUDE],
        maxOutputMw: 100n * POWER_SCALE,
        impulseLimit: 100n * POWER_SCALE,
        volatilityLimit: 1n,
      })
    }
    for (const componentId of [HYDROGEN_BAY, CRUDE_BAY, EMPTY_BAY]) {
      installFuelBay(createTx, config, creation, {
        componentId,
        capacity: 1_000n * POWER_SCALE,
        containmentRating: 10n * POWER_SCALE,
      })
    }
    for (const [componentId, powerReq, drawKind] of Object.values(MODULES)) {
      installGenericModule(createTx, config, creation, {
        componentId,
        typeId: 9n,
        name: 'module',
        data: [1],
        power: { powerReq, drawKind },
      })
    }
    for (const action of [
      'set_fuel_bay',
      'set_power_grid',
      'set_generator',
      'set_desired_state',
    ]) {
      enableAdminAction(createTx, config, creation, action, [
        operateGridRequirement(createTx, config),
      ])
    }
    enableAdminAction(createTx, config, creation, 'deposit_fuel', [
      depositFuelRequirement(createTx, config),
    ])
    shareEntity(createTx, config, creation)
    await expectSuccess(client, createTx)

    const capId = await mintAccessCap(client, config, {
      entity: entityId,
      owner: signer,
      transferable: true,
    })
    const hydrogenVariant = await fuelVariant(client, config, {
      tenant: key.tenant,
      fuelType: HYDROGEN,
      ...FUEL,
    })
    const crudeVariant = await fuelVariant(client, config, {
      tenant: key.tenant,
      fuelType: CRUDE,
      ...FUEL,
    })

    // Hydrogen in an online bay feeds Main; Crude waits in an offline bay;
    // the third bay stays empty. Main and the grid on, two modules wanted on.
    const onTx = new Transaction()
    addSponsors(onTx, config, [signer])
    const entity = onTx.object(entityId)
    const cap = onTx.object(capId)
    for (const [fuelBayId, variant] of [
      [HYDROGEN_BAY, hydrogenVariant],
      [CRUDE_BAY, crudeVariant],
    ] as const) {
      const deposit = interact(onTx, config, entity, 'deposit_fuel')
      depositFuel(onTx, config, entity, deposit, cap, {
        fuelBayId,
        variant,
        amount: UNITS * MASS_UNIT,
      })
      completeRequest(onTx, config, entity, deposit)
    }
    const bay = interact(onTx, config, entity, 'set_fuel_bay')
    setFuelBay(onTx, config, entity, bay, cap, HYDROGEN_BAY, true)
    completeRequest(onTx, config, entity, bay)
    const grid = interact(onTx, config, entity, 'set_power_grid')
    setPowerGrid(onTx, config, entity, grid, cap, true)
    completeRequest(onTx, config, entity, grid)
    const generator = interact(onTx, config, entity, 'set_generator')
    setGenerator(onTx, config, entity, generator, cap, MAIN, true)
    completeRequest(onTx, config, entity, generator)
    for (const [moduleId, , , wanted] of Object.values(MODULES)) {
      if (!wanted) continue
      const desire = interact(onTx, config, entity, 'set_desired_state')
      setDesiredState(onTx, config, entity, desire, cap, moduleId, true)
      completeRequest(onTx, config, entity, desire)
    }
    await expectSuccess(client, onTx)

    // The snapshot and every single reader, in one simulation at one clock.
    const readTx = new Transaction()
    readTx.setSender(signer)
    const target = readTx.object(entityId)
    projectedSnapshot(readTx, config, target)
    projectedPools(readTx, config, target)
    projectedBays(readTx, config, target)
    projectedStatus(readTx, config, target)
    for (const generatorId of [MAIN, SPARE]) {
      generatorStatus(readTx, config, target, generatorId)
    }
    for (const [moduleId] of Object.values(MODULES)) {
      moduleStatus(readTx, config, target, moduleId)
      moduleDraw(readTx, config, target, moduleId)
    }
    const res = await client.simulateTransaction({
      transaction: readTx,
      include: { commandResults: true },
    })
    if (res.FailedTransaction) {
      throw new Error(
        res.FailedTransaction.status.error?.message ?? 'snapshot read failed',
      )
    }
    const results = (res.commandResults ?? []).map((command) =>
      command.returnValues.map((value) => value.bcs),
    )
    const [snapshotBytes, poolsBytes, baysBytes, statusBytes, ...singleBytes] =
      results
    const snapshot = parseProjectedSnapshot(snapshotBytes[0])

    expect(snapshot.pools).toEqual(parseProjectedPools(poolsBytes[0]))
    expect(snapshot.bays).toEqual(parseProjectedBays(baysBytes[0]))
    expect(snapshot.on).toBe(true)
    expect(snapshot.capacityMw).toBe(BigInt(bcs.u64().parse(statusBytes[0])))
    expect(snapshot.usedMw).toBe(BigInt(bcs.u64().parse(statusBytes[1])))

    const [mainStatus, spareStatus, ...moduleBytes] = singleBytes
    const generators = new Map(
      snapshot.generators.map((view) => [view.generatorId, view]),
    )
    expect(generators.get(MAIN)).toMatchObject({
      fuelType: HYDROGEN,
      selectableFuelTypes: [HYDROGEN, CRUDE],
      online: true,
      status: parsePowerStatus(mainStatus[0]),
    })
    expect(generators.get(MAIN)?.outputMw).toBeGreaterThan(0n)
    expect(generators.get(SPARE)).toMatchObject({
      fuelType: CRUDE,
      online: false,
      status: parsePowerStatus(spareStatus[0]),
      outputMw: 0n,
    })

    const modules = new Map(
      snapshot.modules.map((view) => [view.moduleId, view]),
    )
    Object.values(MODULES).forEach(
      ([moduleId, powerReq, drawKind, wanted], i) => {
        const [statusOf, drawOf] = moduleBytes.slice(i * 2, i * 2 + 2)
        expect(modules.get(moduleId)).toMatchObject({
          powerReq,
          drawKind,
          desiredOnline: wanted,
          status: parsePowerStatus(statusOf[0]),
          drawMw: BigInt(bcs.u64().parse(drawOf[0])),
        })
      },
    )

    const bays = new Map(snapshot.bays.map((view) => [view.fuelBayId, view]))
    expect(bays.get(HYDROGEN_BAY)).toMatchObject({
      online: true,
      fuelType: HYDROGEN,
    })
    expect(bays.get(CRUDE_BAY)).toMatchObject({
      online: false,
      fuelType: CRUDE,
    })
    expect(bays.get(EMPTY_BAY)).toMatchObject({ online: false, fuelType: null })
    const hydrogen = snapshot.pools.find(
      (pool) => pool.poolFuelType === HYDROGEN,
    )
    expect(hydrogen?.runOutMs).not.toBeNull()
    expect(hydrogen?.burnRate).toBeGreaterThan(0n)
  })
})
