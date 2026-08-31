import { Transaction } from '@mysten/sui/transactions'
import { signAndExecute } from '../src/client.js'
import { createCharacter } from '../src/packages/character.js'
import { deriveObjectId } from '../src/packages/core.js'
import { loadScriptContext } from './context.js'
import { loadSeedFiles } from './seed-files.js'

const PLAYER_ALIASES = ['PLAYER_A', 'PLAYER_B', 'PLAYER_C'] as const

const { repoRoot, config, client, keypair } = loadScriptContext()
const { resources, accounts } = loadSeedFiles(repoRoot)

for (const alias of PLAYER_ALIASES) {
  if (resources.character[alias] === undefined) {
    throw new Error(`test-resources.json missing character.${alias}`)
  }
  if (!accounts.accounts[alias]?.address) {
    throw new Error(`accounts.json missing accounts.${alias}.address`)
  }
}

const tx = new Transaction()
for (const alias of PLAYER_ALIASES) {
  createCharacter(tx, config, {
    inGameId: BigInt(resources.character[alias]),
    tenant: resources.tenant,
    typeId: 1n,
    tribeId: resources.tribeId,
    owner: accounts.accounts[alias].address,
  })
}

const res = await signAndExecute(client, {
  signer: keypair,
  transaction: tx,
})

console.log('digest:', res.digest)
for (const alias of PLAYER_ALIASES) {
  const key = {
    id: BigInt(resources.character[alias]),
    tenant: resources.tenant,
  }
  console.log(
    `${alias}: id=${key.id} owner=${accounts.accounts[alias].address} objectId=${deriveObjectId(config, key)}`,
  )
}
