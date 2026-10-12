import { bcs } from '@mysten/sui/bcs'
import { Transaction, type TransactionArgument } from '@mysten/sui/transactions'
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
import { installInventory } from '../packages/inventory.js'
import {
  currentFuel,
  currentModuleStatus,
  currentStatus,
  depositFuel,
  depositFuelRequirement,
  installFuel,
  installGenerator,
  installPowerGrid,
  operateGridRequirement,
  POWER_SCALE,
  setDesiredState,
  setGenerator,
  setPowerGrid,
} from '../packages/power.js'
import {
  expectSuccess,
  loadLocalnetWorld,
  mintAccessCap,
  signer,
} from './helpers.js'

const INVENTORY_ID = 0x81n
const GENERATOR_ID = 0x82n
const FUEL_ID = 0x83n
const GENERIC_ID = 0x84n
const ITEM = 88834n

// 20 MW generator. 10 MW inventory + 5 MW thruster, both firm, so both fit.
const OUTPUT = 20n * POWER_SCALE
const INVENTORY_DRAW = 10n * POWER_SCALE
const GENERIC_DRAW = 5n * POWER_SCALE
const USED = INVENTORY_DRAW + GENERIC_DRAW
const CONT_REDUCTION = 10n * POWER_SCALE
// Impulse 0 burns the base rate: 1 fuel unit per second. 25 units lasts ~25s.
const BASE_FUEL_RATE = POWER_SCALE
const FUEL_AMOUNT = 25n * POWER_SCALE
const FUEL_CAPACITY = 1_000n * POWER_SCALE

const OUT_OF_FUEL_WAIT_MS = 70_000
const POLL_MS = 2_000

interface ModuleNow {
  draw: bigint
  desired: boolean
}

interface GridNow {
  fuel: bigint
  capacity: bigint
  used: bigint
  online: bigint[]
  inventory: ModuleNow
  generic: ModuleNow
}

describe('power grid fuel burn (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('reads modules offline once fuel runs out, then regrants them on refuel', async () => {
    const key = { id: 4800n, tenant: 'power-burn' }
    const entityId = deriveObjectId(config, key)

    const createTx = new Transaction()
    const [creation, claim] = entityNew(createTx, config, {
      inGameId: key.id,
      tenant: key.tenant,
    })
    verifyAdmin(createTx, config, claim)
    completeRequest(createTx, config, creation, claim)
    installPowerGrid(createTx, config, creation)
    installGenerator(createTx, config, creation, {
      componentId: GENERATOR_ID,
      name: 'generator',
      maxOutputMw: OUTPUT,
      containmentReduction: CONT_REDUCTION,
      baseFuelRate: BASE_FUEL_RATE,
    })
    installFuel(createTx, config, creation, {
      componentId: FUEL_ID,
      name: 'fuel bay',
      capacity: FUEL_CAPACITY,
    })
    installInventory(createTx, config, creation, {
      componentId: INVENTORY_ID,
      typeId: 1n,
      name: 'inventory',
      capacity: 1000n,
      power: { powerReq: INVENTORY_DRAW, drawKind: 'firm' },
    })
    installGenericModule(createTx, config, creation, {
      componentId: GENERIC_ID,
      typeId: 9n,
      name: 'thruster',
      data: [1],
      power: { powerReq: GENERIC_DRAW, drawKind: 'firm' },
    })
    shareEntity(createTx, config, creation)
    await expectSuccess(client, createTx)

    const capId = await mintAccessCap(client, config, {
      entity: entityId,
      owner: signer,
      transferable: true,
    })

    const enableTx = new Transaction()
    const enabled = enableTx.object(entityId)
    enableAdminAction(enableTx, config, enabled, 'set_power_grid', [
      operateGridRequirement(enableTx, config),
    ])
    enableAdminAction(enableTx, config, enabled, 'set_generator', [
      operateGridRequirement(enableTx, config),
    ])
    enableAdminAction(enableTx, config, enabled, 'set_desired_state', [
      operateGridRequirement(enableTx, config),
    ])
    enableAdminAction(enableTx, config, enabled, 'deposit_fuel', [
      depositFuelRequirement(enableTx, config),
    ])
    await expectSuccess(client, enableTx)

    // Fuel in, grid on, generator on, then desired-online. That last step
    // grants both modules and starts the burn.
    const onlineTx = new Transaction()
    addSponsors(onlineTx, config, [signer])
    const onlineEntity = onlineTx.object(entityId)
    const ownerCap = onlineTx.object(capId)
    deposit(onlineTx, config, onlineEntity, ownerCap, FUEL_AMOUNT)
    const powerRequest = interact(
      onlineTx,
      config,
      onlineEntity,
      'set_power_grid',
    )
    setPowerGrid(onlineTx, config, onlineEntity, powerRequest, ownerCap, true)
    completeRequest(onlineTx, config, onlineEntity, powerRequest)
    const generatorRequest = interact(
      onlineTx,
      config,
      onlineEntity,
      'set_generator',
    )
    setGenerator(
      onlineTx,
      config,
      onlineEntity,
      generatorRequest,
      ownerCap,
      GENERATOR_ID,
      true,
    )
    completeRequest(onlineTx, config, onlineEntity, generatorRequest)
    setDesiredOnline(onlineTx, config, onlineEntity, ownerCap, INVENTORY_ID)
    setDesiredOnline(onlineTx, config, onlineEntity, ownerCap, GENERIC_ID)
    await expectSuccess(client, onlineTx)

    let grid = await readGrid(client, config, entityId)
    expectOnline(grid)

    const deadline = Date.now() + OUT_OF_FUEL_WAIT_MS
    while (grid.fuel > 0n && Date.now() < deadline) {
      const fuelBefore = grid.fuel
      await sleep(POLL_MS)
      grid = await readGrid(client, config, entityId)
      expect(grid.fuel).toBeLessThanOrEqual(fuelBefore)
      if (grid.fuel > 0n) expectOnline(grid)
    }

    expectOutOfFuel(grid)

    const refuelTx = new Transaction()
    addSponsors(refuelTx, config, [signer])
    const refuelEntity = refuelTx.object(entityId)
    deposit(refuelTx, config, refuelEntity, refuelTx.object(capId), FUEL_AMOUNT)
    await expectSuccess(client, refuelTx)

    expectOnline(await readGrid(client, config, entityId))
  })
})

function deposit(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  ownerCap: TransactionArgument,
  amount: bigint,
): void {
  const request = interact(tx, config, entity, 'deposit_fuel')
  depositFuel(tx, config, entity, request, ownerCap, {
    fuelType: ITEM,
    amount,
    impulse: 0n,
    containmentBurden: 0n,
  })
  completeRequest(tx, config, entity, request)
}

function setDesiredOnline(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  ownerCap: TransactionArgument,
  moduleId: bigint,
): void {
  const request = interact(tx, config, entity, 'set_desired_state')
  setDesiredState(tx, config, entity, request, ownerCap, moduleId, true)
  completeRequest(tx, config, entity, request)
}

function expectOnline(now: GridNow): void {
  expect(now.fuel).toBeGreaterThan(0n)
  expect(now.fuel).toBeLessThanOrEqual(FUEL_AMOUNT)
  expect(now.capacity).toBe(OUTPUT)
  expect(now.used).toBe(USED)
  expect(now.online).toEqual([INVENTORY_ID, GENERIC_ID])
  expect(now.inventory).toEqual({ draw: INVENTORY_DRAW, desired: true })
  expect(now.generic).toEqual({ draw: GENERIC_DRAW, desired: true })
}

function expectOutOfFuel(now: GridNow): void {
  expect(now.fuel).toBe(0n)
  expect(now.capacity).toBe(0n)
  expect(now.used).toBe(0n)
  expect(now.online).toEqual([])
  expect(now.inventory).toEqual({ draw: 0n, desired: true })
  expect(now.generic).toEqual({ draw: 0n, desired: true })
}

async function readGrid(
  client: WorldClient,
  config: WorldConfig,
  entityId: string,
): Promise<GridNow> {
  const tx = new Transaction()
  tx.setSender(signer)
  const entity = tx.object(entityId)
  currentFuel(tx, config, entity)
  currentStatus(tx, config, entity)
  currentModuleStatus(tx, config, entity, INVENTORY_ID)
  currentModuleStatus(tx, config, entity, GENERIC_ID)

  const res = await client.simulateTransaction({
    transaction: tx,
    include: { commandResults: true },
  })
  if (res.FailedTransaction) {
    throw new Error(
      res.FailedTransaction.status.error?.message ??
        'current power read failed',
    )
  }
  const commands = res.commandResults
  if (!commands || commands.length !== 4) {
    throw new Error('current power read returned no values')
  }

  const [fuel, status, inventory, generic] = commands
  return {
    fuel: u64(fuel.returnValues[0].bcs),
    capacity: u64(status.returnValues[0].bcs),
    used: u64(status.returnValues[1].bcs),
    online: [...bcs.vector(bcs.u64()).parse(status.returnValues[2].bcs)].map(
      (moduleId) => BigInt(moduleId),
    ),
    inventory: {
      draw: u64(inventory.returnValues[0].bcs),
      desired: bcs.bool().parse(inventory.returnValues[1].bcs),
    },
    generic: {
      draw: u64(generic.returnValues[0].bcs),
      desired: bcs.bool().parse(generic.returnValues[1].bcs),
    },
  }
}

function u64(bytes: Uint8Array): bigint {
  return BigInt(bcs.u64().parse(bytes))
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms)
  })
}
