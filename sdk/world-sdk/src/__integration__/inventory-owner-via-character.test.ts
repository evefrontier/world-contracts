import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import { createCharacter } from '../packages/character.js'
import {
  addSponsors,
  borrowAccess,
  completeRequest,
  deriveObjectId,
  enableAction,
  interact,
  ownerRequirement,
  returnAccess,
  verifyDocking,
  verifyOwner,
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
import { installInventoryPower, powerInventoryOn } from './bring-online.js'
import {
  DOCKED_SHIP,
  dockedProof,
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
      componentId: MODULE_ID,
      typeId: 1n,
      name: UNIT,
      capacity: 1000n,
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
      enableAction(
        enableTx,
        config,
        su,
        'bridge_in',
        [
          ownerRequirement(enableTx, config),
          bridgeInRequirement(enableTx, config, MODULE_ID, {}),
        ],
        suCap,
      )
      enableAction(
        enableTx,
        config,
        su,
        'withdraw',
        [
          ownerRequirement(enableTx, config),
          withdrawRequirement(enableTx, config, MODULE_ID, {}),
        ],
        suCap,
      )
      enableAction(
        enableTx,
        config,
        su,
        'deposit',
        [
          ownerRequirement(enableTx, config),
          depositRequirement(enableTx, config, MODULE_ID, {}),
        ],
        suCap,
      )
      returnAccess(enableTx, config, character, suCap, receipt)
    }
    await expectSuccess(client, enableTx)
    await installInventoryPower(client, config, suId)

    // Assertion PTB: borrow -> power on -> bridge_in 100 -> withdraw 30 -> deposit it back -> return.
    const runTx = new Transaction()
    addSponsors(runTx, config, [signer])
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
      powerInventoryOn(runTx, config, su, suCap, MODULE_ID)

      const bridgeRequest = interact(runTx, config, su, 'bridge_in')
      verifyOwner(runTx, config, su, bridgeRequest, suCap)
      gameItemToChain(runTx, config, su, bridgeRequest, {
        typeId: FUEL,
        quantity: 100n,
        volume: VOL,
      })
      completeRequest(runTx, config, su, bridgeRequest)

      verifyDocking(runTx, config, await dockedProof(config, DOCKED_SHIP, suId))
      const withdrawRequest = interact(runTx, config, su, 'withdraw')
      verifyOwner(runTx, config, su, withdrawRequest, suCap)
      const item = withdraw(runTx, config, su, withdrawRequest, {
        typeId: FUEL,
        quantity: 30n,
      })
      completeRequest(runTx, config, su, withdrawRequest)

      const depositRequest = interact(runTx, config, su, 'deposit')
      verifyOwner(runTx, config, su, depositRequest, suCap)
      deposit(runTx, config, su, depositRequest, item)
      completeRequest(runTx, config, su, depositRequest)

      returnAccess(runTx, config, character, suCap, receipt)
    }
    await expectSuccess(client, runTx)

    // Balance changed (0 -> 100) via the borrowed owner cap.
    const balance = await readBalance(client, config, {
      entity: suId,
      componentId: MODULE_ID,
      typeId: FUEL,
    })
    expect(balance).toBe(100n)

    // The cap is back on the character (object-owned by it).
    const { object: capObj } = await client.getObject({ objectId: suCapId })
    expect(capObj.owner.ObjectOwner ?? capObj.owner.AddressOwner).toBe(
      characterId,
    )
  })
})
