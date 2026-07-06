import { fileURLToPath } from 'node:url'
import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import { createWorldClient } from '../client.js'
import { loadWorldConfig } from '../config/load.js'
import { createCharacter } from '../packages/character.js'
import {
  borrowAccess,
  completeRequest,
  deriveObjectId,
  enableAction,
  interact,
  mintAccess,
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
  capObjectId,
  expectSuccess,
  getObjectRef,
  readBalance,
  requirePackage,
  signer,
} from './helpers.js'

// The SU owner cap is parked on a Character. To use the owner path, borrow
// the cap from the Character inside a PTB, run owner-gated deposit/withdraw on the
// SU, then return the cap — all in one player-signed transaction.
const MANIFEST = fileURLToPath(
  new URL('../../../../deployments/localnet/world.json', import.meta.url),
)

const UNIT = 'SU-05'
const FUEL = 88834n
const VOL = 2n

describe('inventory owner-access via Character', () => {
  const config = loadWorldConfig(MANIFEST)
  const client = createWorldClient({ config })

  it('borrows the parked SU cap, runs the owner path, and returns it', async () => {
    const suKey = { id: 4500n, tenant: 'inventory-t5' }
    const suId = deriveObjectId(config, suKey)
    const charKey = { id: 4501n, tenant: 'inventory-t5' }
    const characterId = deriveObjectId(config, charKey)

    const setupTx = new Transaction()
    createStorageUnit(setupTx, config, {
      inGameId: suKey.id,
      tenant: suKey.tenant,
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

    const coreId = requirePackage(config, 'core')
    // The player's own (soulbound) character cap.
    const charMint = new Transaction()
    mintAccess(charMint, config, {
      entity: characterId,
      owner: signer,
      transferable: false,
    })
    const charCapId = capObjectId(
      await expectSuccess(client, charMint, { showObjectChanges: true }),
      coreId,
    )
    // The SU owner cap, minted straight onto the character object (object-owned).
    const suMint = new Transaction()
    mintAccess(suMint, config, {
      entity: suId,
      owner: characterId,
      transferable: true,
    })
    const suCapId = capObjectId(
      await expectSuccess(client, suMint, { showObjectChanges: true }),
      coreId,
    )

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
          bridgeInRequirement(enableTx, config, UNIT, { ephemeral: false }),
        ],
        [
          'withdraw',
          withdrawRequirement(enableTx, config, UNIT, { ephemeral: false }),
        ],
        [
          'deposit',
          depositRequirement(enableTx, config, UNIT, { ephemeral: false }),
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

      const inReq = interact(runTx, config, su, 'bridge_in')
      verifyProximity(runTx, config, inReq)
      verifyOwner(runTx, config, inReq, suCap)
      gameItemToChain(runTx, config, su, inReq, {
        typeId: FUEL,
        quantity: 100n,
        volume: VOL,
      })
      completeRequest(runTx, config, su, inReq)

      const wReq = interact(runTx, config, su, 'withdraw')
      verifyProximity(runTx, config, wReq)
      verifyOwner(runTx, config, wReq, suCap)
      const item = withdraw(runTx, config, su, wReq, {
        typeId: FUEL,
        quantity: 30n,
      })
      completeRequest(runTx, config, su, wReq)

      const dReq = interact(runTx, config, su, 'deposit')
      verifyProximity(runTx, config, dReq)
      verifyOwner(runTx, config, dReq, suCap)
      deposit(runTx, config, su, dReq, item)
      completeRequest(runTx, config, su, dReq)

      returnAccess(runTx, config, character, suCap, receipt)
    }
    await expectSuccess(client, runTx)

    // Main balance changed (0 -> 100) via the borrowed owner cap.
    const main = await readBalance(client, config, {
      entity: suId,
      name: UNIT,
      authorizedId: suId,
      typeId: FUEL,
    })
    expect(main).toBe(100n)

    // The cap is back on the character (object-owned by it).
    const capObj = await client.getObject({
      id: suCapId,
      options: { showOwner: true },
    })
    const owner = capObj.data?.owner as
      | { ObjectOwner?: string; AddressOwner?: string }
      | undefined
    const parkedOn = owner?.ObjectOwner ?? owner?.AddressOwner
    expect(parkedOn).toBe(characterId)
  })
})
