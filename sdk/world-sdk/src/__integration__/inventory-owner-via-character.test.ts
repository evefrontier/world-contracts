import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import { createCharacter } from '../packages/character.js'
import {
  borrowAccess,
  completeRequest,
  deriveObjectId,
  enableAction,
  interact,
  ownerRequirement,
  returnAccess,
  verifyOwner,
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
  getObjectRef,
  loadLocalnetWorld,
  mintAccessCap,
  readBalance,
  signer,
} from './helpers.js'

// The SU owner cap is parked on a Character. To use the owner path, borrow
// the cap from the Character inside a PTB, run owner-gated deposit/withdraw on the
// SU, then return the cap — all in one player-signed transaction.
const MODULE_ID = 0x51n
const UNIT = 'SU-05'
const FUEL = 88834n
const VOL = 2n

describe('inventory owner-access via Character', () => {
  const { config, client } = loadLocalnetWorld()

  it('borrows the parked SU cap, runs the owner path, and returns it', async () => {
    const suKey = { id: 4500n, tenant: 'inventory-t5' }
    const suId = deriveObjectId(config, suKey)
    const charKey = { id: 4501n, tenant: 'inventory-t5' }
    const characterId = deriveObjectId(config, charKey)

    const setupTx = new Transaction()
    createStorageUnit(setupTx, config, {
      inGameId: suKey.id,
      tenant: suKey.tenant,
      moduleId: MODULE_ID,
      typeId: 1n,
      name: UNIT,
      mainCapacity: 1000n,
      ephemeralCapacity: 100n,
    })
    createCharacter(setupTx, config, {
      inGameId: charKey.id,
      tenant: charKey.tenant,
      tribeId: 1,
      owner: signer,
    })
    await expectSuccess(client, setupTx)

    // The player's own (soulbound) character cap.
    const charCapId = await mintAccessCap(client, config, {
      entity: characterId,
      owner: signer,
      transferable: false,
    })
    // The SU owner cap, minted straight onto the character object (object-owned).
    const suCapId = await mintAccessCap(client, config, {
      entity: suId,
      owner: characterId,
      transferable: true,
    })

    // Setup PTB: borrow the parked cap to enable the owner-gated actions, return it.
    const enableTx = new Transaction()
    {
      const character = enableTx.object(characterId)
      const [suCap, receipt] = borrowAccess(
        enableTx,
        config,
        character,
        enableTx.object(charCapId),
        await getObjectRef(client, suCapId),
      )
      const su = enableTx.object(suId)
      for (const [name, req] of [
        [
          'bridge_in',
          bridgeInRequirement(enableTx, config, MODULE_ID, {
            ephemeral: false,
          }),
        ],
        [
          'withdraw',
          withdrawRequirement(enableTx, config, MODULE_ID, {
            ephemeral: false,
          }),
        ],
        [
          'deposit',
          depositRequirement(enableTx, config, MODULE_ID, { ephemeral: false }),
        ],
      ] as const) {
        enableAction(
          enableTx,
          config,
          su,
          name,
          [ownerRequirement(enableTx, config), req],
          suCap,
        )
      }
      returnAccess(enableTx, config, character, suCap, receipt)
    }
    await expectSuccess(client, enableTx)

    // Assertion PTB: borrow -> bridge_in 100 -> withdraw 30 -> deposit it back -> return.
    const runTx = new Transaction()
    {
      const character = runTx.object(characterId)
      const [suCap, receipt] = borrowAccess(
        runTx,
        config,
        character,
        runTx.object(charCapId),
        await getObjectRef(client, suCapId),
      )
      const su = runTx.object(suId)

      const inReq = interact(runTx, config, su, 'bridge_in', [])
      verifyProximity(runTx, config, inReq, [])
      verifyOwner(runTx, config, inReq, suCap)
      gameItemToChain(runTx, config, su, inReq, {
        typeId: FUEL,
        quantity: 100n,
        volume: VOL,
      })
      completeRequest(runTx, config, su, inReq)

      const wReq = interact(runTx, config, su, 'withdraw', [])
      verifyProximity(runTx, config, wReq, [])
      verifyOwner(runTx, config, wReq, suCap)
      const item = withdraw(runTx, config, su, wReq, {
        typeId: FUEL,
        quantity: 30n,
      })
      completeRequest(runTx, config, su, wReq)

      const dReq = interact(runTx, config, su, 'deposit', [])
      verifyProximity(runTx, config, dReq, [])
      verifyOwner(runTx, config, dReq, suCap)
      deposit(runTx, config, su, dReq, item)
      completeRequest(runTx, config, su, dReq)

      returnAccess(runTx, config, character, suCap, receipt)
    }
    await expectSuccess(client, runTx)

    // Main balance changed (0 -> 100) via the borrowed owner cap.
    const main = await readBalance(client, config, {
      entity: suId,
      moduleId: MODULE_ID,
      authorizedId: suId,
      typeId: FUEL,
    })
    expect(main).toBe(100n)

    // The cap is back on the character (object-owned by it).
    const { object: capObj } = await client.getObject({ objectId: suCapId })
    expect(capObj.owner.ObjectOwner ?? capObj.owner.AddressOwner).toBe(
      characterId,
    )
  })
})
