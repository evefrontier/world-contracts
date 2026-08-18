import { fileURLToPath } from 'node:url'
import 'dotenv/config'
import { bcs } from '@mysten/sui/bcs'
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519'
import { Transaction } from '@mysten/sui/transactions'
import { expect } from 'vitest'
import { createWorldClient } from '../client.js'
import { loadWorldConfig } from '../config/load.js'
import type { WorldConfig } from '../config/types.js'
import { mintAccess } from '../packages/core.js'
import { balanceOf } from '../packages/inventory.js'

export const LOCALNET_MANIFEST = fileURLToPath(
  new URL('../../../../deployments/localnet/world.json', import.meta.url),
)

const privateKey = process.env.SUI_PRIVATE_KEY
if (!privateKey) {
  throw new Error('SUI_PRIVATE_KEY is required (a funded localnet admin key)')
}

export const keypair = Ed25519Keypair.fromSecretKey(privateKey)
export const signer = keypair.toSuiAddress()

type WorldClient = ReturnType<typeof createWorldClient>

export function loadLocalnetWorld(): {
  config: WorldConfig
  client: WorldClient
} {
  const config = loadWorldConfig(LOCALNET_MANIFEST)
  return { config, client: createWorldClient({ config }) }
}

/** Sign, execute, assert success, and wait for the transaction to settle. */
export async function expectSuccess(
  client: WorldClient,
  transaction: Transaction,
  options: { showObjectChanges?: boolean; showEvents?: boolean } = {},
) {
  const result = await client.signAndExecuteTransaction({
    signer: keypair,
    transaction,
    options: { showEffects: true, ...options },
  })
  expect(
    result.effects?.status?.status,
    result.effects?.status?.error ?? '',
  ).toBe('success')
  await client.waitForTransaction({ digest: result.digest })
  return result
}

/** Object id of the `AccessCap` created by a `mintAccess` transaction. */
export function capObjectId(
  minted: Awaited<ReturnType<typeof expectSuccess>>,
  coreId: string,
): string {
  const cap = minted.objectChanges?.find(
    (c) =>
      c.type === 'created' &&
      c.objectType === `${coreId}::access_cap::AccessCap`,
  )
  const id = (cap as { objectId?: string })?.objectId
  if (!id) throw new Error('minted AccessCap not found in object changes')
  return id
}

/** Mint an AccessCap and return its object id. */
export async function mintAccessCap(
  client: WorldClient,
  config: WorldConfig,
  args: { entity: string; owner: string; transferable: boolean },
): Promise<string> {
  const tx = new Transaction()
  mintAccess(tx, config, args)
  return capObjectId(
    await expectSuccess(client, tx, { showObjectChanges: true }),
    requirePackage(config, 'core'),
  )
}

/** Read the `type_id` balance of an inventory via `balance_of` (devInspect). */
export async function readBalance(
  client: WorldClient,
  config: WorldConfig,
  args: { entity: string; name: string; authorizedId: string; typeId: bigint },
): Promise<bigint> {
  const tx = new Transaction()
  balanceOf(tx, config, tx.object(args.entity), {
    name: args.name,
    authorizedId: args.authorizedId,
    typeId: args.typeId,
  })
  const res = await client.devInspectTransactionBlock({
    sender: signer,
    transactionBlock: tx,
  })
  const rv = res.results?.[0]?.returnValues?.[0]
  if (!rv) throw new Error(`balance_of returned no value: ${res.error ?? ''}`)
  return BigInt(bcs.u64().parse(Uint8Array.from(rv[0])))
}

/** Current object ref (id, version, digest) — for building a receiving arg. */
export async function getObjectRef(
  client: WorldClient,
  id: string,
): Promise<{ objectId: string; version: string; digest: string }> {
  const res = await client.getObject({ id })
  const data = res.data
  if (!data) throw new Error(`object ${id} not found`)
  return { objectId: data.objectId, version: data.version, digest: data.digest }
}

export function requirePackage(config: WorldConfig, pkg: string): string {
  const id = config.packageOverrides?.[pkg]
  if (!id) throw new Error(`localnet config must supply the ${pkg} package id`)
  return id
}
