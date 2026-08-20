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

    const createdIds = created.effects.changedObjects
      .filter((o) => o.idOperation === 'Created')
      .map((o) => o.objectId)
    expect(createdIds, `derived ${entityId} not among created`).toContain(
      entityId,
    )

    const capId = await mintAccessCap(client, config, {
      entity: entityId,
      owner: signer,
      transferable: false,
    })

    const { object: capObj } = await client.getObject({ objectId: capId })
    const coreId = requirePackage(config, 'core')
    expect(capObj.type).toBe(`${coreId}::access_cap::AccessCap`)
    expect(capObj.owner.$kind).toBe('AddressOwner')
    expect(capObj.owner.AddressOwner).toBe(signer)
  })
})
