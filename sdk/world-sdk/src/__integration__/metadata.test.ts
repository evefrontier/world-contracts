import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import { createCharacter } from '../packages/character.js'
import {
  borrowAccess,
  completeRequest,
  deriveObjectId,
  enableAction,
  entityNew,
  interact,
  ownerRequirement,
  returnAccess,
  shareEntity,
  verifyAdmin,
  verifyOwner,
  verifyProximity,
} from '../packages/core.js'
import {
  editMetadata,
  editRequirement,
  installMetadata,
} from '../packages/metadata.js'
import {
  expectSuccess,
  getObjectRef,
  loadLocalnetWorld,
  mintAccessCap,
  signer,
} from './helpers.js'

// Entity owner cap is parked on a Character. Borrow it to enable/edit, then return.
describe('metadata owner-access via Character', () => {
  const { config, client } = loadLocalnetWorld()

  it('borrows the parked cap, edits metadata, and returns it', async () => {
    const entityKey = { id: 4600n, tenant: 'metadata-t1' }
    const entityId = deriveObjectId(config, entityKey)
    const charKey = { id: 4601n, tenant: 'metadata-t1' }
    const characterId = deriveObjectId(config, charKey)

    const setupTx = new Transaction()
    {
      const [entity, claimReq] = entityNew(setupTx, config, {
        inGameId: entityKey.id,
        tenant: entityKey.tenant,
      })
      verifyAdmin(setupTx, config, claimReq)
      completeRequest(setupTx, config, entity, claimReq)
      installMetadata(setupTx, config, entity, {
        name: 'Alpha',
        description: 'first',
        url: 'https://example.com/a.png',
      })
      shareEntity(setupTx, config, entity)
    }
    createCharacter(setupTx, config, {
      inGameId: charKey.id,
      tenant: charKey.tenant,
      tribeId: 1,
      owner: signer,
    })
    await expectSuccess(client, setupTx)

    const charCapId = await mintAccessCap(client, config, {
      entity: characterId,
      owner: signer,
      transferable: false,
    })
    const entityCapId = await mintAccessCap(client, config, {
      entity: entityId,
      owner: characterId,
      transferable: true,
    })

    const enableTx = new Transaction()
    {
      const character = enableTx.object(characterId)
      const [entityCap, receipt] = borrowAccess(
        enableTx,
        config,
        character,
        enableTx.object(charCapId),
        await getObjectRef(client, entityCapId),
      )
      enableAction(
        enableTx,
        config,
        enableTx.object(entityId),
        'edit_metadata',
        [ownerRequirement(enableTx, config), editRequirement(enableTx, config)],
        entityCap,
      )
      returnAccess(enableTx, config, character, entityCap, receipt)
    }
    await expectSuccess(client, enableTx)

    const editTx = new Transaction()
    {
      const character = editTx.object(characterId)
      const [entityCap, receipt] = borrowAccess(
        editTx,
        config,
        character,
        editTx.object(charCapId),
        await getObjectRef(client, entityCapId),
      )
      const e = editTx.object(entityId)
      const req = interact(editTx, config, e, 'edit_metadata', [])
      verifyProximity(editTx, config, req, [])
      verifyOwner(editTx, config, req, entityCap)
      editMetadata(editTx, config, e, req, {
        name: 'Beta',
        description: 'updated',
        url: 'https://example.com/b.png',
      })
      completeRequest(editTx, config, e, req)
      returnAccess(editTx, config, character, entityCap, receipt)
    }
    await expectSuccess(client, editTx)

    const capObj = await client.getObject({
      id: entityCapId,
      options: { showOwner: true },
    })
    const owner = capObj.data?.owner as
      | { ObjectOwner?: string; AddressOwner?: string }
      | undefined
    const parkedOn = owner?.ObjectOwner ?? owner?.AddressOwner
    expect(parkedOn).toBe(characterId)
  })
})
