import { fileURLToPath } from 'node:url'
import 'dotenv/config'
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519'
import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import { createWorldClient } from '../client.js'
import { loadWorldConfig } from '../config/load.js'
import { createCharacter } from '../packages/character.js'
import { deriveObjectId, mintAccess } from '../packages/core.js'

// Integration: create a character (tx1, shares the entity), then mint a soulbound
// AccessCap to the owner (tx2), and assert the owner holds it.
const MANIFEST = fileURLToPath(
  new URL('../../../../deployments/localnet/world.json', import.meta.url),
)

const privateKey = process.env.SUI_PRIVATE_KEY
if (!privateKey) {
  throw new Error('SUI_PRIVATE_KEY is required (a funded localnet admin key)')
}
const keypair = Ed25519Keypair.fromSecretKey(privateKey)
const owner = keypair.toSuiAddress()

describe('mintAccess (localnet)', () => {
  const config = loadWorldConfig(MANIFEST)
  const client = createWorldClient({ config })

  it('mints a soulbound AccessCap to the owner of a created character', async () => {
    const key = { id: 99n, tenant: 'mint-access' }
    const entityId = deriveObjectId(config, key)

    const createTx = new Transaction()
    createCharacter(createTx, config, {
      inGameId: key.id,
      tenant: key.tenant,
      tribeId: 1,
      owner,
    })
    const created = await client.signAndExecuteTransaction({
      signer: keypair,
      transaction: createTx,
      options: { showEffects: true },
    })
    expect(
      created.effects?.status?.status,
      created.effects?.status?.error ?? '',
    ).toBe('success')

    const createdIds = (created.effects?.created ?? []).map(
      (c) => c.reference.objectId,
    )
    expect(createdIds, `derived ${entityId} not among created`).toContain(
      entityId,
    )

    await client.waitForTransaction({ digest: created.digest })

    const mintTx = new Transaction()
    mintAccess(mintTx, config, {
      entity: entityId,
      owner,
      transferable: false,
    })
    const minted = await client.signAndExecuteTransaction({
      signer: keypair,
      transaction: mintTx,
      options: { showEffects: true, showObjectChanges: true },
    })
    expect(
      minted.effects?.status?.status,
      minted.effects?.status?.error ?? '',
    ).toBe('success')

    // The mint created exactly one object: a soulbound AccessCap owned by `owner`.
    const createdCap = minted.objectChanges?.find(
      (c) => c.type === 'created' && c.objectType === coreCapType(config),
    )
    const capOwner = (createdCap as { owner?: { AddressOwner?: string } })
      ?.owner?.AddressOwner
    expect(capOwner, 'cap not owned by the intended owner').toBe(owner)
  })
})

function coreCapType(config: ReturnType<typeof loadWorldConfig>): string {
  const coreId = config.packageOverrides?.core
  if (!coreId) {
    throw new Error('localnet config must supply the core package id')
  }
  return `${coreId}::owner_cap::AccessCap`
}
