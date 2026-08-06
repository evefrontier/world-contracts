import { readFileSync } from 'node:fs'

export interface StorageUnitSeed {
  typeId: number
  itemId: number
}

export interface TestResources {
  tenant: string
  tribeId: number
  character: Record<string, number>
  storageUnit?: Record<string, StorageUnitSeed>
}

export interface AccountsFile {
  accounts: Record<string, { address: string }>
}

export function loadSeedFiles(repoRoot: string): {
  resources: TestResources
  accounts: AccountsFile
} {
  const resourcesPath =
    process.env.TEST_RESOURCES_JSON ?? `${repoRoot}/test-resources.json`
  const accountsPath =
    process.env.ACCOUNTS_JSON ?? `${repoRoot}/docker/genesis/accounts.json`
  return {
    resources: JSON.parse(readFileSync(resourcesPath, 'utf8')) as TestResources,
    accounts: JSON.parse(readFileSync(accountsPath, 'utf8')) as AccountsFile,
  }
}
