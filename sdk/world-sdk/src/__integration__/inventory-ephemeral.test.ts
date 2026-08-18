import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import { createCharacter } from '../packages/character.js'
import {
  callerRequirement,
  completeRequest,
  deriveObjectId,
  enableAction,
  interact,
  verifyCaller,
  verifyProximity,
} from '../packages/core.js'
import {
  bridgeInRequirement,
  createStorageUnit,
  gameItemToChain,
  withdraw,
  withdrawRequirement,
} from '../packages/inventory.js'
import {
  expectSuccess,
  loadLocalnetWorld,
  mintAccessCap,
  readBalance,
  signer,
} from './helpers.js'

// A non-owner player brings items into their ephemeral inventory and
// withdraws, using their own (character) caller cap. Ephemeral is keyed by the
// cap's entity, so the player's balance changes while main stays untouched.
const UNIT = 'SU-02'
const FUEL = 88834n
const VOL = 2n

describe('inventory player ephemeral round-trip (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('routes a player bridge_in/withdraw to ephemeral, leaving main untouched', async () => {
    const suKey = { id: 4300n, tenant: 'inventory-t2' }
    const suId = deriveObjectId(config, suKey)
    const playerKey = { id: 4301n, tenant: 'inventory-t2' }
    const characterId = deriveObjectId(config, playerKey)

    // Create the storage unit and a separate character (the ephemeral key holder).
    const setupTx = new Transaction()
    createStorageUnit(setupTx, config, {
      inGameId: suKey.id,
      tenant: suKey.tenant,
      name: UNIT,
      mainCapacity: 1000n,
      ephemeralCapacity: 1000n,
    })
    createCharacter(setupTx, config, {
      inGameId: playerKey.id,
      tenant: playerKey.tenant,
      tribeId: 1,
      owner: signer,
    })
    await expectSuccess(client, setupTx)

    // Mint the SU owner cap (to enable actions) and the player's character cap.
    const ownerCapId = await mintAccessCap(client, config, {
      entity: suId,
      owner: signer,
      transferable: true,
    })
    const playerCapId = await mintAccessCap(client, config, {
      entity: characterId,
      owner: signer,
      transferable: false,
    })

    // Owner enables the ephemeral bridge_in and withdraw actions.
    const enableTx = new Transaction()
    const entity = enableTx.object(suId)
    const ownerCap = enableTx.object(ownerCapId)
    enableAction(
      enableTx,
      config,
      entity,
      'eph_bridge_in',
      [
        callerRequirement(enableTx, config),
        bridgeInRequirement(enableTx, config, UNIT, { ephemeral: true }),
      ],
      ownerCap,
    )
    enableAction(
      enableTx,
      config,
      entity,
      'eph_withdraw',
      [
        callerRequirement(enableTx, config),
        withdrawRequirement(enableTx, config, UNIT, { ephemeral: true }),
      ],
      ownerCap,
    )
    await expectSuccess(client, enableTx)

    // Player brings 30 into their ephemeral inventory, then withdraws 10.
    const runTx = new Transaction()
    const e = runTx.object(suId)
    const playerCap = runTx.object(playerCapId)

    const inReq = interact(runTx, config, e, 'eph_bridge_in')
    verifyProximity(runTx, config, inReq)
    verifyCaller(runTx, config, inReq, playerCap)
    gameItemToChain(runTx, config, e, inReq, {
      typeId: FUEL,
      quantity: 30n,
      volume: VOL,
    })
    completeRequest(runTx, config, e, inReq)

    const outReq = interact(runTx, config, e, 'eph_withdraw')
    verifyProximity(runTx, config, outReq)
    verifyCaller(runTx, config, outReq, playerCap)
    const item = withdraw(runTx, config, e, outReq, {
      typeId: FUEL,
      quantity: 10n,
    })
    completeRequest(runTx, config, e, outReq)
    runTx.transferObjects([item], signer)

    await expectSuccess(client, runTx)

    const ephemeral = await readBalance(client, config, {
      entity: suId,
      name: UNIT,
      authorizedId: characterId,
      typeId: FUEL,
    })
    const main = await readBalance(client, config, {
      entity: suId,
      name: UNIT,
      authorizedId: suId,
      typeId: FUEL,
    })
    expect(ephemeral).toBe(20n)
    expect(main).toBe(0n)
  })
})
