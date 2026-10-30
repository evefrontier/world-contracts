import { bcs } from '@mysten/sui/bcs'
import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import type { WorldClient } from '../client.js'
import type { WorldConfig } from '../config/types.js'
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
  depositFuel,
  depositFuelRequirement,
  installFuelBay,
  installPowerGrid,
  moduleDraw,
  operateFuelModuleRequirement,
  operateGridRequirement,
  POWER_SCALE,
  projectedFuel,
  setDesiredState,
  setFuelBay,
  setFuelModule,
  setPowerGrid,
} from '../packages/power.js'
import {
  expectAbort,
  expectSuccess,
  loadLocalnetWorld,
  mintAccessCap,
  signer,
} from './helpers.js'

const BAY_ID = 0xd1n
const LEAP_ID = 0xd2n
// 1 fuel unit per second, at `POWER_SCALE`.
const LEAP_RATE = POWER_SCALE
const BURN_WAIT_MS = 4_000

describe('fuel modules (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('burns a leap rate from the bays while the service keeps it online', async () => {
    const key = { id: 4960n, tenant: 'fuel-modules' }
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
    installGenericModule(createTx, config, creation, {
      componentId: LEAP_ID,
      typeId: 9n,
      name: 'leap drive',
      data: [1],
      power: { powerReq: 0n, powerKind: 'fuel' },
    })
    for (const action of [
      'set_fuel_bay',
      'set_power_grid',
      'set_desired_state',
    ]) {
      enableAdminAction(createTx, config, creation, action, [
        operateGridRequirement(createTx, config),
      ])
    }
    enableAdminAction(createTx, config, creation, 'deposit_fuel', [
      depositFuelRequirement(createTx, config),
    ])
    enableAdminAction(createTx, config, creation, 'set_fuel_module', [
      operateFuelModuleRequirement(createTx, config),
    ])
    shareEntity(createTx, config, creation)
    await expectSuccess(client, createTx)

    const capId = await mintAccessCap(client, config, {
      entity: entityId,
      owner: signer,
      transferable: true,
    })

    // Fuel in, bay online, grid on. No generator: only the leap will burn.
    const onTx = new Transaction()
    addSponsors(onTx, config, [signer])
    const entity = onTx.object(entityId)
    const cap = onTx.object(capId)
    const fuel = interact(onTx, config, entity, 'deposit_fuel')
    depositFuel(onTx, config, entity, fuel, cap, {
      fuelBayId: BAY_ID,
      fuelType: 1n,
      amount: 500n,
      impulse: 90n * POWER_SCALE,
      containmentBurden: 14n * POWER_SCALE,
      volatility: 1n * POWER_SCALE,
    })
    completeRequest(onTx, config, entity, fuel)
    const bay = interact(onTx, config, entity, 'set_fuel_bay')
    setFuelBay(onTx, config, entity, bay, cap, BAY_ID, true)
    completeRequest(onTx, config, entity, bay)
    const grid = interact(onTx, config, entity, 'set_power_grid')
    setPowerGrid(onTx, config, entity, grid, cap, true)
    completeRequest(onTx, config, entity, grid)
    await expectSuccess(client, onTx)

    // The owner can't switch a fuel module; the service does.
    const ownerTx = new Transaction()
    const ownerEntity = ownerTx.object(entityId)
    const desired = interact(ownerTx, config, ownerEntity, 'set_desired_state')
    setDesiredState(
      ownerTx,
      config,
      ownerEntity,
      desired,
      ownerTx.object(capId),
      LEAP_ID,
      true,
    )
    completeRequest(ownerTx, config, ownerEntity, desired)
    await expectAbort(client, ownerTx, signer, /ENotPowerModule/)

    const leapOn = new Transaction()
    setFuelModule(
      leapOn,
      config,
      leapOn.object(entityId),
      LEAP_ID,
      true,
      LEAP_RATE,
    )
    await expectSuccess(client, leapOn)
    expect(await readLeap(client, config, entityId)).toBe(LEAP_RATE)

    const before = await readFuel(client, config, entityId)
    await sleep(BURN_WAIT_MS)
    const during = await readFuel(client, config, entityId)
    expect(during).toBeLessThan(before)

    // Offline again: the burn stops.
    const leapOff = new Transaction()
    setFuelModule(leapOff, config, leapOff.object(entityId), LEAP_ID, false, 0n)
    await expectSuccess(client, leapOff)
    const stopped = await readFuel(client, config, entityId)
    await sleep(BURN_WAIT_MS)
    expect(await readFuel(client, config, entityId)).toBe(stopped)
    expect(await readLeap(client, config, entityId)).toBe(0n)
  })
})

async function readU64(
  client: WorldClient,
  build: (tx: Transaction) => void,
): Promise<bigint> {
  const tx = new Transaction()
  tx.setSender(signer)
  build(tx)
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

function readFuel(
  client: WorldClient,
  config: WorldConfig,
  entityId: string,
): Promise<bigint> {
  return readU64(client, (tx) => projectedFuel(tx, config, tx.object(entityId)))
}

function readLeap(
  client: WorldClient,
  config: WorldConfig,
  entityId: string,
): Promise<bigint> {
  return readU64(client, (tx) =>
    moduleDraw(tx, config, tx.object(entityId), LEAP_ID),
  )
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms)
  })
}
