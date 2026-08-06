import { readFileSync } from 'node:fs'
import { Transaction } from '@mysten/sui/transactions'
import { createCharacter } from '../src/packages/character.js'
import { deriveObjectId } from '../src/packages/core.js'
import { loadScriptContext } from './context.js'

const PLAYER_ALIASES = ['PLAYER_A', 'PLAYER_B', 'PLAYER_C'] as const
type PlayerAlias = (typeof PLAYER_ALIASES)[number]

interface TestResources {
  tenant: string
  tribeId: number
  character: Record<PlayerAlias, number>
}

interface AccountsFile {
  accounts: Record<string, { address: string }>
}

const { repoRoot, config, client, keypair } = loadScriptContext()
const resourcesPath =
  process.env.TEST_RESOURCES_JSON ?? `${repoRoot}/test-resources.json`
const accountsPath =
  process.env.ACCOUNTS_JSON ?? `${repoRoot}/docker/genesis/accounts.json`

const resources = JSON.parse(
  readFileSync(resourcesPath, 'utf8'),
) as TestResources
const accounts = JSON.parse(readFileSync(accountsPath, 'utf8')) as AccountsFile

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
    tribeId: resources.tribeId,
    owner: accounts.accounts[alias].address,
  })
}

const res = await client.signAndExecuteTransaction({
  signer: keypair,
  transaction: tx,
  options: { showEffects: true, showObjectChanges: true },
})

const status = res.effects?.status
console.log('status:', status?.status, status?.error ?? '')
for (const alias of PLAYER_ALIASES) {
  const key = {
    id: BigInt(resources.character[alias]),
    tenant: resources.tenant,
  }
  console.log(
    `${alias}: id=${key.id} owner=${accounts.accounts[alias].address} objectId=${deriveObjectId(config, key)}`,
  )
}

if (status?.status !== 'success') {
  process.exitCode = 1
}
