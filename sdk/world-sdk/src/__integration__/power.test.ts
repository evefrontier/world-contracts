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
  depositFuel,
  depositFuelRequirement,
  installFuelBay,
  installGenerator,
  operateGridRequirement,
  POWER_SCALE,
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
  readBalance,
  signer,
} from './helpers.js'

// A module draws while its desired state is online and the grid can carry it.
// Bridge-in pushes an online check, so it succeeds only while the inventory
// holds its grant and the grid still has fuel.
const INVENTORY_ID = 0x61n
const GENERATOR_ID = 0x62n
const FUEL_ID = 0x63n
const ITEM = 88834n
const VOL = 2n
// 15 MW generator, 10 MW inventory draw, containment reduction 10.
const OUTPUT = 15n
const DRAW = 10n
const CONT_REDUCTION = 10n * POWER_SCALE
const BASE_FUEL_RATE = POWER_SCALE
// 500 units of fuel: impulse 90, containment burden 14.
const FUEL_AMOUNT = 500n * POWER_SCALE
const IMPULSE = 90n * POWER_SCALE
const BURDEN = 14n * POWER_SCALE
const VOLATILITY = POWER_SCALE / 2n

function eventNames(result: ExecutedTransaction): string[] {
  return (result.events ?? []).map(
    (event) => event.eventType.split('::').pop() ?? '',
  )
}

describe('power grid powers an inventory (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('onlines an inventory, gates its action, and drops the grant when the generator goes offline', async () => {
    const key = { id: 4300n, tenant: 'power-t1' }
    const entityId = deriveObjectId(config, key)

    // tx1: storage unit. The grid is installed first, then the inventory connects to it.
    const createTx = new Transaction()
    createStorageUnit(createTx, config, {
      inGameId: key.id,
      tenant: key.tenant,
      componentId: INVENTORY_ID,
      typeId: 1n,
      name: 'Storage Unit And Power Grid',
      capacity: 1000n,
      power: { powerReq: DRAW, drawKind: 'firm' },
    })
    await expectSuccess(client, createTx)

    const installTx = new Transaction()
    const installEntity = installTx.object(entityId)
    installGenerator(installTx, config, installEntity, {
      componentId: GENERATOR_ID,
      maxOutputMw: OUTPUT,
      containmentReduction: CONT_REDUCTION,
      baseFuelRate: BASE_FUEL_RATE,
    })
    installFuelBay(installTx, config, installEntity, {
      componentId: FUEL_ID,
      capacity: 1000n,
    })
    await expectSuccess(client, installTx)

    const capId = await mintAccessCap(client, config, {
      entity: entityId,
      owner: signer,
      transferable: true,
    })

    // tx2: admin exposes each grid step and the powered bridge.
    const enableTx = new Transaction()
    const enableEntity = enableTx.object(entityId)
    enableAdminAction(enableTx, config, enableEntity, 'set_power_grid', [
      operateGridRequirement(enableTx, config),
    ])
    enableAdminAction(enableTx, config, enableEntity, 'set_generator', [
      operateGridRequirement(enableTx, config),
    ])
    enableAdminAction(enableTx, config, enableEntity, 'set_fuel_bay', [
      operateGridRequirement(enableTx, config),
    ])
    enableAdminAction(enableTx, config, enableEntity, 'set_desired_state', [
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
    ])
    await expectSuccess(client, enableTx)

    // tx3: owner deposits fuel (signer is also the sponsor), brings the bay
    // online, powers on, brings the generator online, and asks the inventory to draw.
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
      fuelBayId: FUEL_ID,
      fuelType: ITEM,
      amount: FUEL_AMOUNT,
      impulse: IMPULSE,
      containmentBurden: BURDEN,
      volatility: VOLATILITY,
    })
    completeRequest(onlineTx, config, onlineEntity, depositFuelRequest)
    const setFuelBayRequest = interact(
      onlineTx,
      config,
      onlineEntity,
      'set_fuel_bay',
    )
    setFuelBay(
      onlineTx,
      config,
      onlineEntity,
      setFuelBayRequest,
      cap,
      FUEL_ID,
      true,
    )
    completeRequest(onlineTx, config, onlineEntity, setFuelBayRequest)
    const setPowerGridRequest = interact(
      onlineTx,
      config,
      onlineEntity,
      'set_power_grid',
    )
    setPowerGrid(onlineTx, config, onlineEntity, setPowerGridRequest, cap, true)
    completeRequest(onlineTx, config, onlineEntity, setPowerGridRequest)
    const setGeneratorOnlineRequest = interact(
      onlineTx,
      config,
      onlineEntity,
      'set_generator',
    )
    setGenerator(
      onlineTx,
      config,
      onlineEntity,
      setGeneratorOnlineRequest,
      cap,
      GENERATOR_ID,
      true,
    )
    completeRequest(onlineTx, config, onlineEntity, setGeneratorOnlineRequest)
    const desiredRequest = interact(
      onlineTx,
      config,
      onlineEntity,
      'set_desired_state',
    )
    setDesiredState(
      onlineTx,
      config,
      onlineEntity,
      desiredRequest,
      cap,
      INVENTORY_ID,
      true,
    )
    completeRequest(onlineTx, config, onlineEntity, desiredRequest)
    const online = await expectSuccess(client, onlineTx)
    expect(eventNames(online)).toContain('FuelAdded')
    expect(eventNames(online)).toContain('DrawChanged')

    // tx4: the powered bridge works while the inventory holds its grant.
    const bridge = () => {
      const tx = new Transaction()
      const bridgeEntity = tx.object(entityId)
      const bridgeInItemsRequest = interact(
        tx,
        config,
        bridgeEntity,
        'bridge_in_items',
      )
      verifyOwner(
        tx,
        config,
        bridgeEntity,
        bridgeInItemsRequest,
        tx.object(capId),
      )
      gameItemToChain(tx, config, bridgeEntity, bridgeInItemsRequest, {
        typeId: ITEM,
        quantity: 10n,
        volume: VOL,
      })
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

    // tx5: generator offline -> capacity 0 -> the inventory's grant drops to zero.
    const offlineTx = new Transaction()
    const offlineEntity = offlineTx.object(entityId)
    const setGeneratorOfflineRequest = interact(
      offlineTx,
      config,
      offlineEntity,
      'set_generator',
    )
    setGenerator(
      offlineTx,
      config,
      offlineEntity,
      setGeneratorOfflineRequest,
      offlineTx.object(capId),
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
    expect(eventNames(offline)).toContain('DrawChanged')

    // tx6: the inventory has no grant, so the powered bridge now aborts.
    await expectAbort(client, bridge(), signer, /no power granted/i)
  })
})
