import { bcs } from '@mysten/sui/bcs'
import { Transaction, type TransactionArgument } from '@mysten/sui/transactions'
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
  depositFuel,
  depositFuelRequirement,
  installFuelBay,
  installGenerator,
  installPowerGrid,
  moduleDraw,
  moduleStatus,
  operateGridRequirement,
  POWER_SCALE,
  type PowerStatus,
  parsePowerStatus,
  setDesiredState,
  setFuelBay,
  setGenerator,
  setPowerGrid,
  shutDown,
  shutDownRequirement,
} from '../packages/power.js'
import {
  expectSuccess,
  loadLocalnetWorld,
  mintAccessCap,
  signer,
} from './helpers.js'

const GENERATOR_ID = 0xf0n
const BAY_ID = 0xf1n
const MODULE_ID = 0xf2n
const DRAW = 10n

describe('shut down (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('keeps intent through Power Off and clears it on shut down', async () => {
    const key = { id: 4980n, tenant: 'shut-down' }
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
      maxOutputMw: 15n,
      containmentReduction: 10n,
      baseFuelRate: 1n,
    })
    installFuelBay(createTx, config, creation, {
      componentId: BAY_ID,
      capacity: 1_000n,
    })
    installGenericModule(createTx, config, creation, {
      componentId: MODULE_ID,
      typeId: 9n,
      name: 'module',
      data: [1],
      power: { powerReq: DRAW, drawKind: 'firm' },
    })
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
    enableAdminAction(createTx, config, creation, 'shut_down', [
      shutDownRequirement(createTx, config),
    ])
    shareEntity(createTx, config, creation)
    await expectSuccess(client, createTx)

    const capId = await mintAccessCap(client, config, {
      entity: entityId,
      owner: signer,
      transferable: true,
    })

    // Fuel, bay, grid, generator and module on.
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
    owner(onTx, entity, 'set_fuel_bay', (request) =>
      setFuelBay(onTx, config, entity, request, cap, BAY_ID, true),
    )
    owner(onTx, entity, 'set_power_grid', (request) =>
      setPowerGrid(onTx, config, entity, request, cap, true),
    )
    owner(onTx, entity, 'set_generator', (request) =>
      setGenerator(onTx, config, entity, request, cap, GENERATOR_ID, true),
    )
    owner(onTx, entity, 'set_desired_state', (request) =>
      setDesiredState(onTx, config, entity, request, cap, MODULE_ID, true),
    )
    await expectSuccess(client, onTx)
    expect(await readDraw(entityId)).toBe(DRAW)
    expect(await readStatus(entityId)).toBe('online')

    // Power Off then On: the module comes back by itself.
    await powerCycle(entityId, capId)
    expect(await readDraw(entityId)).toBe(DRAW)

    // Shut down (the service, when the Shell leaves): a power cycle brings nothing back.
    const shutTx = new Transaction()
    shutDown(shutTx, config, shutTx.object(entityId))
    await expectSuccess(client, shutTx)
    expect(await readDraw(entityId)).toBe(0n)
    expect(await readStatus(entityId)).toBe('off')
    await powerCycle(entityId, capId)
    expect(await readDraw(entityId)).toBe(0n)
  })

  function owner(
    tx: Transaction,
    entity: TransactionArgument,
    action: string,
    handler: (request: TransactionArgument) => void,
  ): void {
    const request = interact(tx, config, entity, action)
    handler(request)
    completeRequest(tx, config, entity, request)
  }

  async function powerCycle(entityId: string, capId: string): Promise<void> {
    const tx = new Transaction()
    const entity = tx.object(entityId)
    const cap = tx.object(capId)
    for (const on of [false, true]) {
      owner(tx, entity, 'set_power_grid', (request) =>
        setPowerGrid(tx, config, entity, request, cap, on),
      )
    }
    await expectSuccess(client, tx)
  }

  async function readStatus(entityId: string): Promise<PowerStatus> {
    const tx = new Transaction()
    tx.setSender(signer)
    moduleStatus(tx, config, tx.object(entityId), MODULE_ID)
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
    return parsePowerStatus(value.bcs)
  }

  async function readDraw(entityId: string): Promise<bigint> {
    const tx = new Transaction()
    tx.setSender(signer)
    moduleDraw(tx, config, tx.object(entityId), MODULE_ID)
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
