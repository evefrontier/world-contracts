/**
 * Finalize EVE currency registration in the CoinRegistry (0xc).
 *
 * Usage:
 *   ENV=localnet pnpm --filter @evefrontier/world-sdk finalize:eve
 */
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { Transaction } from '@mysten/sui/transactions'
import 'dotenv/config'
import { signAndExecute } from '../src/client.js'
import { EVE_CURRENCY } from '../src/config/shared-objects.js'
import type { SharedObjectRef } from '../src/config/types.js'
import { loadScriptContext } from './context.js'

const COIN_REGISTRY_ID = '0xc'
const CURRENCY_PACKAGE = 'currency'

interface Manifest {
  chainId: string
  packages: Record<string, { publishedAt: string }>
  sharedObjects: Record<string, SharedObjectRef>
  mvr?: Record<string, unknown>
}

function createdCurrencyId(
  objectChanges: Array<{
    type: string
    objectId?: string
    objectType?: string
  }>,
  currencyType: string,
): string {
  const created = objectChanges.find(
    (c) => c.type === 'created' && c.objectType === currencyType && c.objectId,
  )
  if (!created?.objectId) {
    throw new Error(`Currency not found in object changes: ${currencyType}`)
  }
  return created.objectId
}

async function main(): Promise<void> {
  const { deployEnv, repoRoot, manifestPath, client, keypair } =
    loadScriptContext()
  const deployDir = join(repoRoot, 'deployments', deployEnv)
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as Manifest

  const packageId = manifest.packages[CURRENCY_PACKAGE]?.publishedAt
  if (!packageId) {
    throw new Error(`world.json missing packages.${CURRENCY_PACKAGE}`)
  }

  const coinType = `${packageId}::EVE::EVE`
  const currencyType = `0x2::coin_registry::Currency<${coinType}>`

  if (manifest.sharedObjects[EVE_CURRENCY]?.type === currencyType) {
    console.log(`sharedObjects.${EVE_CURRENCY} already set; skipping.`)
    return
  }

  const publishPath = join(deployDir, `${CURRENCY_PACKAGE}.publish.json`)
  if (!existsSync(publishPath)) {
    throw new Error(`missing publish output: ${publishPath}`)
  }
  const { objectChanges: publishChanges } = JSON.parse(
    readFileSync(publishPath, 'utf8'),
  ) as {
    objectChanges?: Array<{
      type: string
      objectId?: string
      objectType?: string
    }>
  }
  const currencyObjectId = createdCurrencyId(publishChanges ?? [], currencyType)

  const { object } = await client.getObject({ objectId: currencyObjectId })
  const currencyRef = {
    objectId: object.objectId,
    version: object.version,
    digest: object.digest,
  }

  const tx = new Transaction()
  tx.setSender(keypair.getPublicKey().toSuiAddress())
  tx.moveCall({
    target: '0x2::coin_registry::finalize_registration',
    typeArguments: [coinType],
    arguments: [
      tx.object(COIN_REGISTRY_ID),
      tx.receivingRef(currencyRef),
    ],
  })

  const result = await signAndExecute(client, {
    transaction: tx,
    signer: keypair,
  })

  const sharedId = result.effects.changedObjects.find(
    (o) =>
      o.idOperation === 'Created' &&
      result.objectTypes[o.objectId] === currencyType,
  )?.objectId
  if (!sharedId) {
    throw new Error(`Currency not found in object changes: ${currencyType}`)
  }

  manifest.sharedObjects[EVE_CURRENCY] = {
    id: sharedId,
    type: currencyType,
  }
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`)

  console.log('EVE currency finalized in CoinRegistry.')
  console.log('Digest:', result.digest)
  console.log(`sharedObjects.${EVE_CURRENCY}=${sharedId}`)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
