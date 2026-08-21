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
  deposit,
  depositRequirement,
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

// Owner configures a multi-requirement swap (give a fuel from your ephemeral,
// get a lens from main). A player executes the whole swap in one PTB with one
// signer — no owner cap at call time, since the requirements are owner-trusted.
const MODULE_ID = 0x51n
const UNIT = 'SU-03'
const FUEL = 88834n
const LENS = 55n
const VOL = 2n

describe('inventory owner-configured swap (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('swaps a player fuel for a main lens in one player-signed PTB', async () => {
    const suKey = { id: 4400n, tenant: 'inventory-t3' }
    const suId = deriveObjectId(config, suKey)
    const playerKey = { id: 4401n, tenant: 'inventory-t3' }
    const characterId = deriveObjectId(config, playerKey)

    const setupTx = new Transaction()
    createStorageUnit(setupTx, config, {
      inGameId: suKey.id,
      tenant: suKey.tenant,
      moduleId: MODULE_ID,
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

    // Owner enables the main and ephemeral bridge_in actions plus the swap.
    const enableTx = new Transaction()
    const entity = enableTx.object(suId)
    const ownerCap = enableTx.object(ownerCapId)
    enableAction(
      enableTx,
      config,
      entity,
      'bridge_in',
      [
        callerRequirement(enableTx, config),
        bridgeInRequirement(enableTx, config, MODULE_ID, { ephemeral: false }),
      ],
      ownerCap,
    )
    enableAction(
      enableTx,
      config,
      entity,
      'eph_bridge_in',
      [
        callerRequirement(enableTx, config),
        bridgeInRequirement(enableTx, config, MODULE_ID, { ephemeral: true }),
      ],
      ownerCap,
    )
    // swap: from ephemeral fuel -> main; from main lens -> ephemeral.
    enableAction(
      enableTx,
      config,
      entity,
      'swap',
      [
        callerRequirement(enableTx, config),
        withdrawRequirement(enableTx, config, MODULE_ID, {
          ephemeral: true,
          typeId: FUEL,
        }),
        depositRequirement(enableTx, config, MODULE_ID, {
          ephemeral: false,
          typeId: FUEL,
        }),
        withdrawRequirement(enableTx, config, MODULE_ID, {
          ephemeral: false,
          typeId: LENS,
        }),
        depositRequirement(enableTx, config, MODULE_ID, {
          ephemeral: true,
          typeId: LENS,
        }),
      ],
      ownerCap,
    )
    await expectSuccess(client, enableTx)

    // Owner stocks a lens in main.
    const stockTx = new Transaction()
    const se = stockTx.object(suId)
    const stockReq = interact(stockTx, config, se, 'bridge_in', [])
    verifyProximity(stockTx, config, stockReq, [])
    verifyCaller(stockTx, config, stockReq, stockTx.object(ownerCapId))
    gameItemToChain(stockTx, config, se, stockReq, {
      typeId: LENS,
      quantity: 1n,
      volume: VOL,
    })
    completeRequest(stockTx, config, se, stockReq)
    await expectSuccess(client, stockTx)

    // Player brings a fuel into their ephemeral, then swaps.
    const runTx = new Transaction()
    const e = runTx.object(suId)
    const playerCap = runTx.object(playerCapId)

    const inReq = interact(runTx, config, e, 'eph_bridge_in', [])
    verifyProximity(runTx, config, inReq, [])
    verifyCaller(runTx, config, inReq, playerCap)
    gameItemToChain(runTx, config, e, inReq, {
      typeId: FUEL,
      quantity: 1n,
      volume: VOL,
    })
    completeRequest(runTx, config, e, inReq)

    const swapReq = interact(runTx, config, e, 'swap', [])
    verifyProximity(runTx, config, swapReq, [])
    verifyCaller(runTx, config, swapReq, playerCap)
    const fuel = withdraw(runTx, config, e, swapReq, {
      typeId: FUEL,
      quantity: 1n,
    })
    deposit(runTx, config, e, swapReq, fuel)
    const lens = withdraw(runTx, config, e, swapReq, {
      typeId: LENS,
      quantity: 1n,
    })
    deposit(runTx, config, e, swapReq, lens)
    completeRequest(runTx, config, e, swapReq)

    await expectSuccess(client, runTx)

    const read = (authorizedId: string, typeId: bigint) =>
      readBalance(client, config, {
        entity: suId,
        moduleId: MODULE_ID,
        authorizedId,
        typeId,
      })

    expect(await read(suId, FUEL)).toBe(1n) // fuel now in main
    expect(await read(suId, LENS)).toBe(0n) // lens left main
    expect(await read(characterId, LENS)).toBe(1n) // lens now in player ephemeral
    expect(await read(characterId, FUEL)).toBe(0n) // fuel left ephemeral
  })
})
