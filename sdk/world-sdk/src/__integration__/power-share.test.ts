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
  assertFits,
  type DrawKind,
  depositFuel,
  depositFuelRequirement,
  fitsRequirement,
  installFuelBay,
  installGenerator,
  installPowerGrid,
  moduleDraw,
  operateGridRequirement,
  setDesiredState,
  setFuelBay,
  setGenerator,
  setPowerGrid,
} from '../packages/power.js'
import {
  expectAbort,
  expectSuccess,
  loadLocalnetWorld,
  mintAccessCap,
  signer,
} from './helpers.js'

const GENERATOR_ID = 0xc0n
const BAY_ID = 0xc1n
// The overview's power example on a 100 MW limit.
const MODULES: Record<string, [bigint, bigint, DrawKind]> = {
  A: [0xcan, 70n, 'firm'],
  B: [0xcbn, 20n, 'firm'],
  C: [0xccn, 30n, 'elastic'],
  D: [0xcdn, 10n, 'firm'],
  E: [0xcen, 20n, 'firm'],
}
type Name = keyof typeof MODULES

describe('power sharing (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('grants firm needs all or nothing and shares the leftover with elastic asks', async () => {
    const key = { id: 4950n, tenant: 'power-share' }
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
      maxOutputMw: 100n,
      containmentReduction: 10n,
      baseFuelRate: 1n,
    })
    installFuelBay(createTx, config, creation, {
      componentId: BAY_ID,
      capacity: 10_000n,
    })
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
    // The owner's pre-filtered switch: the operation, then the overload check.
    enableAdminAction(createTx, config, creation, 'set_desired_state_fitted', [
      operateGridRequirement(createTx, config),
      fitsRequirement(createTx, config),
    ])
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

    // Plenty of fuel, bay and generator online, grid on.
    const onTx = new Transaction()
    addSponsors(onTx, config, [signer])
    const entity = onTx.object(entityId)
    const cap = onTx.object(capId)
    const fuel = interact(onTx, config, entity, 'deposit_fuel')
    depositFuel(onTx, config, entity, fuel, cap, {
      fuelBayId: BAY_ID,
      fuelType: 1n,
      amount: 9_000n,
      impulse: 90n,
      containmentBurden: 14n,
      volatility: 1n,
    })
    completeRequest(onTx, config, entity, fuel)
    const bay = interact(onTx, config, entity, 'set_fuel_bay')
    setFuelBay(onTx, config, entity, bay, cap, BAY_ID, true)
    completeRequest(onTx, config, entity, bay)
    const grid = interact(onTx, config, entity, 'set_power_grid')
    setPowerGrid(onTx, config, entity, grid, cap, true)
    completeRequest(onTx, config, entity, grid)
    const generator = interact(onTx, config, entity, 'set_generator')
    setGenerator(onTx, config, entity, generator, cap, GENERATOR_ID, true)
    completeRequest(onTx, config, entity, generator)
    await expectSuccess(client, onTx)

    const desire = async (names: Name[], online: boolean) => {
      const tx = new Transaction()
      const target = tx.object(entityId)
      for (const name of names) {
        const request = interact(tx, config, target, 'set_desired_state')
        setDesiredState(
          tx,
          config,
          target,
          request,
          tx.object(capId),
          MODULES[name][0],
          online,
        )
        completeRequest(tx, config, target, request)
      }
      await expectSuccess(client, tx)
      return readDraws(client, config, entityId)
    }

    expect(await desire(['A', 'B'], true)).toMatchObject({ A: 70n, B: 20n })
    expect(await desire(['C'], true)).toMatchObject({ C: 10n })
    expect(await desire(['D'], true)).toMatchObject({ C: 0n, D: 10n })
    expect(await desire(['E'], true)).toEqual({
      A: 0n,
      B: 0n,
      C: 0n,
      D: 0n,
      E: 0n,
    })
    expect(await desire(['E'], false)).toEqual({
      A: 70n,
      B: 20n,
      C: 0n,
      D: 10n,
      E: 0n,
    })

    // With the pre-filter, E's switch-on aborts instead of overloading.
    const fittedTx = new Transaction()
    const fitted = fittedTx.object(entityId)
    const request = interact(
      fittedTx,
      config,
      fitted,
      'set_desired_state_fitted',
    )
    setDesiredState(
      fittedTx,
      config,
      fitted,
      request,
      fittedTx.object(capId),
      MODULES.E[0],
      true,
    )
    assertFits(fittedTx, config, fitted, request)
    completeRequest(fittedTx, config, fitted, request)
    await expectAbort(client, fittedTx, signer, /EWouldOverload/)
    expect(await readDraws(client, config, entityId)).toMatchObject({
      A: 70n,
      B: 20n,
      D: 10n,
    })
  })
})

async function readDraws(
  client: WorldClient,
  config: WorldConfig,
  entityId: string,
): Promise<Record<Name, bigint>> {
  const tx = new Transaction()
  tx.setSender(signer)
  const names = Object.keys(MODULES) as Name[]
  for (const name of names) {
    moduleDraw(tx, config, tx.object(entityId), MODULES[name][0])
  }
  const res = await client.simulateTransaction({
    transaction: tx,
    include: { commandResults: true },
  })
  if (res.FailedTransaction) {
    throw new Error(
      res.FailedTransaction.status.error?.message ?? 'module draw read failed',
    )
  }
  const commands = res.commandResults ?? []
  return Object.fromEntries(
    names.map((name, i) => [
      name,
      BigInt(bcs.u64().parse(commands[i].returnValues[0].bcs)),
    ]),
  ) as Record<Name, bigint>
}
