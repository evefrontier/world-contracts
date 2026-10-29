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
import {
  type DepositFuelArgs,
  depositFuel,
  depositFuelRequirement,
  installFuelBay,
  installGenerator,
  installPowerGrid,
  operateGridRequirement,
  POWER_SCALE,
  type ProjectedBay,
  parseProjectedBays,
  projectedBays,
  setDesiredState,
  setFuelBay,
  setGenerator,
  setPowerGrid,
} from '../packages/power.js'
import {
  expectSuccess,
  loadLocalnetWorld,
  mintAccessCap,
  signer,
} from './helpers.js'

const GENERATOR_ID = 0xa0n
const BAY_A = 0xa1n
const BAY_B = 0xa2n
const MODULE_ID = 0xa3n
// 10 MW generator at containment reduction 10 sends 10 MW to a 10 MW module.
const OUTPUT = 10n
const DRAW = 10n
const CONT_REDUCTION = 10n * POWER_SCALE
const BAY_CAPACITY = 2_000n
const BURN_WAIT_MS = 4_000

// The overview's fuels, at `POWER_SCALE`.
const FUEL_A = {
  fuelType: 1n,
  amount: 1_000n * POWER_SCALE,
  impulse: 250_000n,
  containmentBurden: 40_000n,
  volatility: 6_000n,
}
const FUEL_B = {
  fuelType: 2n,
  amount: 500n * POWER_SCALE,
  impulse: 900_000n,
  containmentBurden: 140_000n,
  volatility: 5_000n,
}

describe('fuel bays (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('blends per bay, keeps an offline reserve, and burns online bays in proportion', async () => {
    const key = { id: 4900n, tenant: 'fuel-bays' }
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
      maxOutputMw: OUTPUT,
      containmentReduction: CONT_REDUCTION,
      baseFuelRate: POWER_SCALE,
    })
    for (const componentId of [BAY_A, BAY_B]) {
      installFuelBay(createTx, config, creation, {
        componentId,
        capacity: BAY_CAPACITY,
      })
    }
    installGenericModule(createTx, config, creation, {
      componentId: MODULE_ID,
      typeId: 9n,
      name: 'thruster',
      data: [1],
      power: { powerReq: DRAW, drawKind: 'firm' },
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
    for (const action of [
      'set_fuel_bay',
      'set_power_grid',
      'set_generator',
      'set_desired_state',
    ]) {
      enableAdminAction(enableTx, config, enabled, action, [
        operateGridRequirement(enableTx, config),
      ])
    }
    enableAdminAction(enableTx, config, enabled, 'deposit_fuel', [
      depositFuelRequirement(enableTx, config),
    ])
    await expectSuccess(client, enableTx)

    // Fuel A then fuel B into bay A blend; bay B holds fuel B alone.
    const fuelTx = new Transaction()
    addSponsors(fuelTx, config, [signer])
    const fuelEntity = fuelTx.object(entityId)
    const fuelCap = fuelTx.object(capId)
    deposit(fuelTx, config, fuelEntity, fuelCap, {
      fuelBayId: BAY_A,
      ...FUEL_A,
    })
    deposit(fuelTx, config, fuelEntity, fuelCap, {
      fuelBayId: BAY_A,
      ...FUEL_B,
    })
    deposit(fuelTx, config, fuelEntity, fuelCap, {
      fuelBayId: BAY_B,
      ...FUEL_B,
    })
    await expectSuccess(client, fuelTx)

    const loaded = await readBays(client, config, entityId)
    expect(loaded.get(BAY_A)).toMatchObject({
      online: false,
      quantity: 15_000_000n,
      impulse: 466_666n,
      containmentBurden: 73_333n,
      volatility: 5_666n,
    })
    expect(loaded.get(BAY_B)).toMatchObject({
      online: false,
      quantity: FUEL_B.amount,
    })

    // Bay A online, grid on, generator on, module on: the burn starts.
    const onlineTx = new Transaction()
    const onlineEntity = onlineTx.object(entityId)
    const onlineCap = onlineTx.object(capId)
    operate(onlineTx, config, onlineEntity, 'set_fuel_bay', (request) =>
      setFuelBay(
        onlineTx,
        config,
        onlineEntity,
        request,
        onlineCap,
        BAY_A,
        true,
      ),
    )
    operate(onlineTx, config, onlineEntity, 'set_power_grid', (request) =>
      setPowerGrid(onlineTx, config, onlineEntity, request, onlineCap, true),
    )
    operate(onlineTx, config, onlineEntity, 'set_generator', (request) =>
      setGenerator(
        onlineTx,
        config,
        onlineEntity,
        request,
        onlineCap,
        GENERATOR_ID,
        true,
      ),
    )
    operate(onlineTx, config, onlineEntity, 'set_desired_state', (request) =>
      setDesiredState(
        onlineTx,
        config,
        onlineEntity,
        request,
        onlineCap,
        MODULE_ID,
        true,
      ),
    )
    await expectSuccess(client, onlineTx)

    // Only the online bay burns; the offline reserve keeps its fuel.
    await sleep(BURN_WAIT_MS)
    const reserveKept = await readBays(client, config, entityId)
    expect(amountOf(reserveKept, BAY_A)).toBeLessThan(15_000_000n)
    expect(amountOf(reserveKept, BAY_B)).toBe(FUEL_B.amount)

    // Bring the reserve online: both bays now burn, each by what it holds.
    const reserveTx = new Transaction()
    const reserveEntity = reserveTx.object(entityId)
    operate(reserveTx, config, reserveEntity, 'set_fuel_bay', (request) =>
      setFuelBay(
        reserveTx,
        config,
        reserveEntity,
        request,
        reserveTx.object(capId),
        BAY_B,
        true,
      ),
    )
    await expectSuccess(client, reserveTx)

    const before = await readBays(client, config, entityId)
    await sleep(BURN_WAIT_MS)
    const after = await readBays(client, config, entityId)
    const [a0, b0] = [amountOf(before, BAY_A), amountOf(before, BAY_B)]
    const [a1, b1] = [amountOf(after, BAY_A), amountOf(after, BAY_B)]
    expect(a1).toBeLessThan(a0)
    expect(b1).toBeLessThan(b0)
    // Proportional burn keeps the ratio a / b, up to one rounding step per bay.
    const drift = a1 * b0 - b1 * a0
    expect(drift < 0n ? -drift : drift).toBeLessThanOrEqual(a0 + b0)
  })
})

function deposit(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  ownerCap: TransactionArgument,
  args: DepositFuelArgs,
): void {
  const request = interact(tx, config, entity, 'deposit_fuel')
  depositFuel(tx, config, entity, request, ownerCap, args)
  completeRequest(tx, config, entity, request)
}

/** Run owner action `action`, satisfying it with `handler`. */
function operate(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  action: string,
  handler: (request: TransactionArgument) => void,
): void {
  const request = interact(tx, config, entity, action)
  handler(request)
  completeRequest(tx, config, entity, request)
}

async function readBays(
  client: WorldClient,
  config: WorldConfig,
  entityId: string,
): Promise<Map<bigint, ProjectedBay>> {
  const tx = new Transaction()
  tx.setSender(signer)
  projectedBays(tx, config, tx.object(entityId))
  const res = await client.simulateTransaction({
    transaction: tx,
    include: { commandResults: true },
  })
  if (res.FailedTransaction) {
    throw new Error(
      res.FailedTransaction.status.error?.message ??
        'projected bays read failed',
    )
  }
  const value = res.commandResults?.at(-1)?.returnValues[0]
  if (!value) throw new Error('projected bays read returned no value')
  return new Map(
    parseProjectedBays(value.bcs).map((bay) => [bay.fuelBayId, bay]),
  )
}

function amountOf(bays: Map<bigint, ProjectedBay>, fuelBayId: bigint): bigint {
  const bay = bays.get(fuelBayId)
  if (!bay) throw new Error(`fuel bay ${fuelBayId} not installed`)
  return bay.quantity
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms)
  })
}
