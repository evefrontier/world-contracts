import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import { createCharacter } from '../packages/character.js'
import { deriveObjectId } from '../packages/core.js'
import {
  expectSuccess,
  loadLocalnetWorld,
  mintAccessCap,
  requirePackage,
  signer,
} from './helpers.js'

// Integration: create a character (tx1, shares the entity), then mint a soulbound
// AccessCap to the owner (tx2), and assert the owner holds it.
describe('mintAccess (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('mints a soulbound AccessCap to the owner of a created character', async () => {
    const key = { id: 99n, tenant: 'mint-access' }
    const entityId = deriveObjectId(config, key)

    const createTx = new Transaction()
    createCharacter(createTx, config, {
      inGameId: key.id,
      tenant: key.tenant,
      tribeId: 1,
      owner: signer,
    })
    const created = await expectSuccess(client, createTx)

    const createdIds = (created.effects?.created ?? []).map(
      (c) => c.reference.objectId,
    )
    expect(createdIds, `derived ${entityId} not among created`).toContain(
      entityId,
    )

    const capId = await mintAccessCap(client, config, {
      entity: entityId,
      owner: signer,
      transferable: false,
    })

    const capObj = await client.getObject({
      id: capId,
      options: { showOwner: true, showType: true },
    })
    const coreId = requirePackage(config, 'core')
    expect(capObj.data?.type).toBe(`${coreId}::access_cap::AccessCap`)
    const capOwner = (
      capObj.data?.owner as { AddressOwner?: string } | undefined
    )?.AddressOwner
    expect(capOwner, 'cap not owned by the intended owner').toBe(signer)
  })
})
