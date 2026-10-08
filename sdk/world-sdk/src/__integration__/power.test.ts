import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import type { ExecutedTransaction } from '../client.js'
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
  gameItemToChain,
} from '../packages/inventory.js'
import {
  assertReserved,
  connectModule,
  depositFuel,
  depositFuelRequirement,
  installFuel,
  installGenerator,
  installPowerGrid,
  manageFuelRequirement,
  manageGeneratorRequirement,
  manageModuleRequirement,
  operateGridRequirement,
  POWER_SCALE,
  registerFuelSource,
  registerGenerator,
  reserve,
  reserveRequirement,
  setGenerator,
  setPowerGrid,
} from '../packages/power.js'
import {
  expectAbort,
  expectSuccess,
  loadLocalnetWorld,
  mintAccessCap,
  readBalance,
  signer,
} from './helpers.js'

// A module is online while it holds a reservation. `bridge_in_items`
// includes `reserve_requirement`, so the bridge succeeds only while the
// inventory stays reserved and the grid still has fuel.
const INVENTORY_ID = 0x61n
const GENERATOR_ID = 0x62n
const FUEL_ID = 0x63n
const ITEM = 88834n
const VOL = 2n
// 15 MW generator, 10 MW inventory draw, containment reduction 10.
const OUTPUT = 15n * POWER_SCALE
const DRAW = 10n * POWER_SCALE
const CONT_REDUCTION = 10n * POWER_SCALE
const BASE_FUEL_RATE = POWER_SCALE
// 500 units of fuel: impulse 90, containment burden 14.
const FUEL_AMOUNT = 500n * POWER_SCALE
const IMPULSE = 90n * POWER_SCALE
const BURDEN = 14n * POWER_SCALE

function eventNames(result: ExecutedTransaction): string[] {
  return (result.events ?? []).map(
    (event) => event.eventType.split('::').pop() ?? '',
  )
}

describe('power grid powers an inventory (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('onlines an inventory, gates its action, and sheds when the generator goes offline', async () => {
    const key = { id: 4300n, tenant: 'power-t1' }
    const entityId = deriveObjectId(config, key)

    // tx1: storage unit with an inventory, plus grid, generator and fuel bay.
    const createTx = new Transaction()
    createStorageUnit(createTx, config, {
      inGameId: key.id,
      tenant: key.tenant,
      componentId: INVENTORY_ID,
      typeId: 1n,
      name: 'Storage Unit And Power Grid',
      capacity: 1000n,
    })
    await expectSuccess(client, createTx)

    const installTx = new Transaction()
    const installEntity = installTx.object(entityId)
    installPowerGrid(installTx, config, installEntity)
    installGenerator(installTx, config, installEntity, GENERATOR_ID)
    installFuel(installTx, config, installEntity, FUEL_ID)
    await expectSuccess(client, installTx)

    const capId = await mintAccessCap(client, config, {
      entity: entityId,
      owner: signer,
      transferable: true,
    })

    // tx2: admin exposes each grid step and the powered bridge.
    const enableTx = new Transaction()
    const enableEntity = enableTx.object(entityId)
    enableAdminAction(enableTx, config, enableEntity, 'register_generator', [
      manageGeneratorRequirement(enableTx, config),
    ])
    enableAdminAction(enableTx, config, enableEntity, 'connect_module', [
      manageModuleRequirement(enableTx, config),
    ])
    enableAdminAction(enableTx, config, enableEntity, 'register_fuel_source', [
      manageFuelRequirement(enableTx, config),
    ])
    enableAdminAction(enableTx, config, enableEntity, 'set_power_grid', [
      ownerRequirement(enableTx, config),
      operateGridRequirement(enableTx, config),
    ])
    enableAdminAction(enableTx, config, enableEntity, 'set_generator', [
      ownerRequirement(enableTx, config),
      operateGridRequirement(enableTx, config),
    ])
    enableAdminAction(enableTx, config, enableEntity, 'reserve', [
      ownerRequirement(enableTx, config),
      operateGridRequirement(enableTx, config),
    ])
    enableAdminAction(enableTx, config, enableEntity, 'deposit_fuel', [
      depositFuelRequirement(enableTx, config, {
        minImpulse: 50n * POWER_SCALE,
      }),
    ])
    enableAdminAction(enableTx, config, enableEntity, 'bridge_in_items', [
      ownerRequirement(enableTx, config),
      bridgeInRequirement(enableTx, config, INVENTORY_ID, {}),
      reserveRequirement(enableTx, config, INVENTORY_ID, DRAW, 'firm'),
    ])
    await expectSuccess(client, enableTx)

    // tx3: admin registers the generator and fuel bay, and attaches the inventory.
    const attachModuleTx = new Transaction()
    const attachModuleEntity = attachModuleTx.object(entityId)
    const registerGeneratorRequest = interact(
      attachModuleTx,
      config,
      attachModuleEntity,
      'register_generator',
    )
    registerGenerator(
      attachModuleTx,
      config,
      attachModuleEntity,
      registerGeneratorRequest,
      {
        generatorId: GENERATOR_ID,
        maxOutputMw: OUTPUT,
        containmentReduction: CONT_REDUCTION,
        baseFuelRate: BASE_FUEL_RATE,
      },
    )
    completeRequest(
      attachModuleTx,
      config,
      attachModuleEntity,
      registerGeneratorRequest,
    )
    const registerFuelSourceRequest = interact(
      attachModuleTx,
      config,
      attachModuleEntity,
      'register_fuel_source',
    )
    registerFuelSource(
      attachModuleTx,
      config,
      attachModuleEntity,
      registerFuelSourceRequest,
      FUEL_ID,
      1000n * POWER_SCALE,
    )
    completeRequest(
      attachModuleTx,
      config,
      attachModuleEntity,
      registerFuelSourceRequest,
    )
    const connectModuleRequest = interact(
      attachModuleTx,
      config,
      attachModuleEntity,
      'connect_module',
    )
    connectModule(
      attachModuleTx,
      config,
      attachModuleEntity,
      connectModuleRequest,
      INVENTORY_ID,
      0n,
    )
    completeRequest(
      attachModuleTx,
      config,
      attachModuleEntity,
      connectModuleRequest,
    )
    await expectSuccess(client, attachModuleTx)

    // tx4: owner deposits fuel (signer is also the sponsor), powers on,
    // brings the generator online and reserves power for the inventory.
    const onlineTx = new Transaction()
    addSponsors(onlineTx, config, [signer])
    const onlineEntity = onlineTx.object(entityId)
    const cap = onlineTx.object(capId)
    const depositFuelRequest = interact(
      onlineTx,
      config,
      onlineEntity,
      'deposit_fuel',
    )
    depositFuel(onlineTx, config, onlineEntity, depositFuelRequest, cap, {
      fuelType: ITEM,
      amount: FUEL_AMOUNT,
      impulse: IMPULSE,
      containmentBurden: BURDEN,
    })
    completeRequest(onlineTx, config, onlineEntity, depositFuelRequest)
    const setPowerGridRequest = interact(
      onlineTx,
      config,
      onlineEntity,
      'set_power_grid',
    )
    verifyOwner(onlineTx, config, setPowerGridRequest, cap)
    setPowerGrid(onlineTx, config, onlineEntity, setPowerGridRequest, true)
    completeRequest(onlineTx, config, onlineEntity, setPowerGridRequest)
    const setGeneratorOnlineRequest = interact(
      onlineTx,
      config,
      onlineEntity,
      'set_generator',
    )
    verifyOwner(onlineTx, config, setGeneratorOnlineRequest, cap)
    setGenerator(
      onlineTx,
      config,
      onlineEntity,
      setGeneratorOnlineRequest,
      GENERATOR_ID,
      true,
    )
    completeRequest(onlineTx, config, onlineEntity, setGeneratorOnlineRequest)
    const reserveRequest = interact(onlineTx, config, onlineEntity, 'reserve')
    verifyOwner(onlineTx, config, reserveRequest, cap)
    reserve(
      onlineTx,
      config,
      onlineEntity,
      reserveRequest,
      INVENTORY_ID,
      DRAW,
      'firm',
    )
    completeRequest(onlineTx, config, onlineEntity, reserveRequest)
    const online = await expectSuccess(client, onlineTx)
    expect(eventNames(online)).toContain('FuelAdded')
    expect(eventNames(online)).toContain('Reserved')

    // tx5: the powered bridge works while the inventory is online.
    const bridge = () => {
      const tx = new Transaction()
      const bridgeEntity = tx.object(entityId)
      const bridgeInItemsRequest = interact(
        tx,
        config,
        bridgeEntity,
        'bridge_in_items',
      )
      verifyOwner(tx, config, bridgeInItemsRequest, tx.object(capId))
      gameItemToChain(tx, config, bridgeEntity, bridgeInItemsRequest, {
        typeId: ITEM,
        quantity: 10n,
        volume: VOL,
      })
      assertReserved(tx, config, bridgeEntity, bridgeInItemsRequest)
      completeRequest(tx, config, bridgeEntity, bridgeInItemsRequest)
      return tx
    }
    await expectSuccess(client, bridge())
    const balance = await readBalance(client, config, {
      entity: entityId,
      componentId: INVENTORY_ID,
      typeId: ITEM,
    })
    expect(balance).toBe(10n)

    // tx6: generator offline -> capacity 0 -> the inventory's reservation is shed.
    const offlineTx = new Transaction()
    const offlineEntity = offlineTx.object(entityId)
    const setGeneratorOfflineRequest = interact(
      offlineTx,
      config,
      offlineEntity,
      'set_generator',
    )
    verifyOwner(
      offlineTx,
      config,
      setGeneratorOfflineRequest,
      offlineTx.object(capId),
    )
    setGenerator(
      offlineTx,
      config,
      offlineEntity,
      setGeneratorOfflineRequest,
      GENERATOR_ID,
      false,
    )
    completeRequest(
      offlineTx,
      config,
      offlineEntity,
      setGeneratorOfflineRequest,
    )
    const offline = await expectSuccess(client, offlineTx)
    expect(eventNames(offline)).toContain('Shed')

    // tx7: the inventory is offline, so the powered bridge now aborts.
    await expectAbort(client, bridge(), signer, /reservation/i)
  })
})
