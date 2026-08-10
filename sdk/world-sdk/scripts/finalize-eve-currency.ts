/**
 * Finalize EVE currency registration in the CoinRegistry (0xc).
 * Run after publishing the currency package (deploy-currency.sh does this).
 *
 * Usage:
 *   ENV=localnet pnpm --filter @evefrontier/world-sdk finalize:eve
 */
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { Transaction } from '@mysten/sui/transactions'
import 'dotenv/config'
import { EVE_CURRENCY } from '../src/config/shared-objects.js'
import type { SharedObjectRef } from '../src/config/types.js'
import { loadScriptContext } from './context.js'

const COIN_REGISTRY_ID = '0xc'
const CURRENCY_PACKAGE = 'currency'

interface CreatedChange {
  type: 'created'
  objectId: string
  objectType: string
}

interface Manifest {
  chainId: string
  packages: Record<string, { publishedAt: string }>
  sharedObjects: Record<string, SharedObjectRef>
  mvr?: Record<string, unknown>
}

function readManifest(path: string): Manifest {
  if (!existsSync(path)) throw new Error(`missing manifest: ${path}`)
  return JSON.parse(readFileSync(path, 'utf8')) as Manifest
}

function writeManifest(path: string, manifest: Manifest): void {
  writeFileSync(path, `${JSON.stringify(manifest, null, 2)}\n`)
}

function currencyIdFromPublish(deployDir: string, packageId: string): string {
  const path = join(deployDir, `${CURRENCY_PACKAGE}.publish.json`)
  if (!existsSync(path)) throw new Error(`missing publish output: ${path}`)
  const { objectChanges } = JSON.parse(readFileSync(path, 'utf8')) as {
    objectChanges?: CreatedChange[]
  }
  const eveType = `${packageId}::EVE::EVE`
  const currencyType = `0x2::coin_registry::Currency<${eveType}>`
  const created = (objectChanges ?? []).find(
    (c) => c.type === 'created' && c.objectType === currencyType,
  )
  if (!created) throw new Error(`Currency<EVE> not found in ${path}`)
  return created.objectId
}

function sharedVersion(owner: unknown): string | undefined {
  if (typeof owner !== 'object' || owner === null || !('Shared' in owner)) {
    return undefined
  }
  const v = (owner as { Shared?: { initial_shared_version?: number | string } })
    .Shared?.initial_shared_version
  if (v === undefined || v === null) return undefined
  return String(v)
}

async function main(): Promise<void> {
  const { deployEnv, repoRoot, manifestPath, client, keypair } =
    loadScriptContext()
  const deployDir = join(repoRoot, 'deployments', deployEnv)
  const manifest = readManifest(manifestPath)

  if (manifest.sharedObjects[EVE_CURRENCY]) {
    console.log(`sharedObjects.${EVE_CURRENCY} already set; skipping finalize.`)
    return
  }

  const packageId = manifest.packages[CURRENCY_PACKAGE]?.publishedAt
  if (!packageId) {
    throw new Error(`world.json missing packages.${CURRENCY_PACKAGE}`)
  }

  const currencyObjectId = currencyIdFromPublish(deployDir, packageId)
  const coinType = `${packageId}::EVE::EVE`
  const currencyType = `0x2::coin_registry::Currency<${coinType}>`
  const sender = keypair.getPublicKey().toSuiAddress()

  const res = await client.getObject({
    id: currencyObjectId,
    options: { showOwner: true },
  })
  if (!res.data) {
    throw new Error(`Currency object not found: ${currencyObjectId}`)
  }

  const alreadyShared = sharedVersion(res.data.owner)
  if (alreadyShared !== undefined) {
    manifest.sharedObjects[EVE_CURRENCY] = {
      id: currencyObjectId,
      initialSharedVersion: alreadyShared,
      type: currencyType,
    }
    writeManifest(manifestPath, manifest)
    console.log(
      `Currency already shared; wrote sharedObjects.${EVE_CURRENCY}=${currencyObjectId}`,
    )
    return
  }

  const { objectId, version, digest } = res.data
  const tx = new Transaction()
  tx.setSender(sender)
  tx.moveCall({
    target: `${packageId}::EVE::complete_registration`,
    arguments: [
      tx.object(COIN_REGISTRY_ID),
      tx.receivingRef({ objectId, version, digest }),
    ],
  })

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer: keypair,
    options: { showEffects: true },
  })

  if (result.effects?.status?.status !== 'success') {
    console.error('Finalize failed:', result.effects?.status)
    process.exit(1)
  }

  const after = await client.getObject({
    id: currencyObjectId,
    options: { showOwner: true },
  })
  const versionAfter = sharedVersion(after.data?.owner)
  if (versionAfter === undefined) {
    throw new Error('Currency did not become shared after finalize')
  }

  manifest.sharedObjects[EVE_CURRENCY] = {
    id: currencyObjectId,
    initialSharedVersion: versionAfter,
    type: currencyType,
  }
  writeManifest(manifestPath, manifest)

  console.log('EVE currency finalized in CoinRegistry.')
  console.log('Digest:', result.digest)
  console.log(`sharedObjects.${EVE_CURRENCY}=${currencyObjectId}`)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
