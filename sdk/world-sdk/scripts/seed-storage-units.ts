import { Transaction } from '@mysten/sui/transactions'
import { signAndExecute } from '../src/client.js'
import { deriveObjectId, mintAccess } from '../src/packages/core.js'
import { createStorageUnit } from '../src/packages/inventory.js'
import { loadScriptContext } from './context.js'
import { loadSeedFiles } from './seed-files.js'

const UNIT_NAME = 'SU'
const MAIN_CAPACITY = 1000n
const EPHEMERAL_CAPACITY = 100n

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
    moduleId: BigInt(unit.itemId),
    name: UNIT_NAME,
    mainCapacity: MAIN_CAPACITY,
    ephemeralCapacity: EPHEMERAL_CAPACITY,
  })
}

const created = await signAndExecute(client, {
  signer: keypair,
  transaction: createTx,
})
console.log('create digest:', created.digest)
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

const minted = await signAndExecute(client, {
  signer: keypair,
  transaction: mintTx,
})
console.log('mint digest:', minted.digest)
await client.waitForTransaction({ digest: minted.digest })

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
