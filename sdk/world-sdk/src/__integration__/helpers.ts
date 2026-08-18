import { fileURLToPath } from 'node:url'
import 'dotenv/config'
import { bcs } from '@mysten/sui/bcs'
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519'
import { Transaction } from '@mysten/sui/transactions'
import {
  type ExecutedTransaction,
  type WorldClient,
  createWorldClient,
  signAndExecute,
} from '../client.js'
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
): Promise<ExecutedTransaction> {
  const result = await signAndExecute(client, {
    signer: keypair,
    transaction,
  })
  await client.waitForTransaction({ digest: result.digest })
  return result
}

/** Object id of the `AccessCap` created by a `mintAccess` transaction. */
export function capObjectId(
  minted: ExecutedTransaction,
  coreId: string,
): string {
  const type = `${coreId}::access_cap::AccessCap`
  const id = minted.effects.changedObjects.find(
    (o) =>
      o.idOperation === 'Created' && minted.objectTypes[o.objectId] === type,
  )?.objectId
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
    await expectSuccess(client, tx),
    requirePackage(config, 'core'),
  )
}

/** Read the `type_id` balance of an inventory via `balance_of` (simulate). */
export async function readBalance(
  client: WorldClient,
  config: WorldConfig,
  args: { entity: string; name: string; authorizedId: string; typeId: bigint },
): Promise<bigint> {
  const tx = new Transaction()
  tx.setSender(signer)
  balanceOf(tx, config, tx.object(args.entity), {
    name: args.name,
    authorizedId: args.authorizedId,
    typeId: args.typeId,
  })
  const res = await client.simulateTransaction({
    transaction: tx,
    include: { commandResults: true },
  })
  if (res.FailedTransaction) {
    throw new Error(
      `balance_of simulation failed: ${res.FailedTransaction.status.error?.message ?? ''}`,
    )
  }
  const rv = res.commandResults[0]?.returnValues[0]
  if (!rv) throw new Error('balance_of returned no value')
  return BigInt(bcs.u64().parse(rv.bcs))
}

/** Current object ref (id, version, digest) — for building a receiving arg. */
export async function getObjectRef(
  client: WorldClient,
  id: string,
): Promise<{ objectId: string; version: string; digest: string }> {
  const { object } = await client.getObject({ objectId: id })
  return {
    objectId: object.objectId,
    version: object.version,
    digest: object.digest,
  }
}

export function requirePackage(config: WorldConfig, pkg: string): string {
  const id = config.packageOverrides?.[pkg]
  if (!id) throw new Error(`localnet config must supply the ${pkg} package id`)
  return id
}
