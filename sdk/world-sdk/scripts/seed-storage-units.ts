import { Transaction } from '@mysten/sui/transactions'
import { deriveObjectId, mintAccess } from '../src/packages/core.js'
import { createStorageUnit } from '../src/packages/inventory.js'
import { loadScriptContext } from './context.js'
import { loadSeedFiles } from './seed-files.js'

const UNIT_NAME = 'SU'
const MAIN_CAPACITY = 1000n
const EPHEMERAL_CAPACITY = 100n
const LOCATION_HASH = Array.from(new TextEncoder().encode('loc'))

const { repoRoot, config, client, keypair } = loadScriptContext()
const { resources, accounts } = loadSeedFiles(repoRoot)

const entries = Object.entries(resources.storageUnit ?? {})
if (entries.length === 0) {
  console.log('no storageUnit entries in test-resources.json; nothing to do.')
  process.exit(0)
}

for (const [alias, unit] of entries) {
  if (unit.typeId === undefined || unit.itemId === undefined) {
    throw new Error(
      `test-resources.json storageUnit.${alias} needs typeId and itemId`,
    )
  }
  if (resources.character[alias] === undefined) {
    throw new Error(
      `storageUnit.${alias} has no matching character.${alias} to own the cap`,
    )
  }
  if (!accounts.accounts[alias]?.address) {
    throw new Error(`accounts.json missing accounts.${alias}.address`)
  }
}

const createTx = new Transaction()
for (const [, unit] of entries) {
  createStorageUnit(createTx, config, {
    inGameId: BigInt(unit.itemId),
    tenant: resources.tenant,
    locationHash: LOCATION_HASH,
    name: UNIT_NAME,
    mainCapacity: MAIN_CAPACITY,
    ephemeralCapacity: EPHEMERAL_CAPACITY,
  })
}

const created = await client.signAndExecuteTransaction({
  signer: keypair,
  transaction: createTx,
  options: { showEffects: true },
})
const createStatus = created.effects?.status
console.log('create status:', createStatus?.status, createStatus?.error ?? '')
if (createStatus?.status !== 'success') {
  process.exitCode = 1
  process.exit(1)
}
await client.waitForTransaction({ digest: created.digest })

const mintTx = new Transaction()
for (const [alias, unit] of entries) {
  const suId = deriveObjectId(config, {
    id: BigInt(unit.itemId),
    tenant: resources.tenant,
  })
  const characterId = deriveObjectId(config, {
    id: BigInt(resources.character[alias]),
    tenant: resources.tenant,
  })
  mintAccess(mintTx, config, {
    entity: suId,
    owner: characterId,
    transferable: true,
  })
}

const minted = await client.signAndExecuteTransaction({
  signer: keypair,
  transaction: mintTx,
  options: { showEffects: true },
})
const mintStatus = minted.effects?.status
console.log('mint status:', mintStatus?.status, mintStatus?.error ?? '')
if (mintStatus?.status === 'success') {
  await client.waitForTransaction({ digest: minted.digest })
}

for (const [alias, unit] of entries) {
  const suId = deriveObjectId(config, {
    id: BigInt(unit.itemId),
    tenant: resources.tenant,
  })
  const characterId = deriveObjectId(config, {
    id: BigInt(resources.character[alias]),
    tenant: resources.tenant,
  })
  console.log(
    `${alias}: typeId=${unit.typeId} itemId=${unit.itemId} objectId=${suId} capOwner=${characterId}`,
  )
}

if (mintStatus?.status !== 'success') {
  process.exitCode = 1
}
