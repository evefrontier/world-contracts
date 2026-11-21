import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import 'dotenv/config'
import { bcs } from '@mysten/sui/bcs'
import type { Signer } from '@mysten/sui/cryptography'
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519'
import { Transaction, type TransactionArgument } from '@mysten/sui/transactions'
import { expect } from 'vitest'
import {
  createWorldClient,
  type ExecutedTransaction,
  requireExecutedTx,
  signAndExecute,
  type WorldClient,
} from '../client.js'
import { loadWorldConfig } from '../config/load.js'
import type { WorldConfig } from '../config/types.js'
import { componentIdFromName } from '../packages/component-id.js'
import { mintAccess } from '../packages/core.js'
import { balanceOf } from '../packages/inventory.js'
import { installLayout, setShell } from '../packages/layout.js'
import { deriveVariantId, registerVariant } from '../packages/variant.js'

export const LOCALNET_MANIFEST = fileURLToPath(
  new URL('../../../../deployments/localnet/world.json', import.meta.url),
)

const privateKey = process.env.SUI_PRIVATE_KEY
if (!privateKey) {
  throw new Error('SUI_PRIVATE_KEY is required (a funded localnet admin key)')
}

export const keypair = Ed25519Keypair.fromSecretKey(privateKey)
export const signer = keypair.toSuiAddress()

export const GRID_ID = componentIdFromName('power_grid')
/** Same placeholder the Move tests seat: `object::id_from_address(@0x5E11)`. */
export const SHELL_ID = '0x5e11'

/** Seat a Shell in the power grid so the grid can switch things on. */
export function seatShell(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
): void {
  installLayout(tx, config, entity, [{ sectionId: 1n, moduleIds: [GRID_ID] }])
  setShell(tx, config, entity, SHELL_ID, GRID_ID)
}

export function loadLocalnetWorld(): {
  config: WorldConfig
  client: WorldClient
} {
  const config = loadWorldConfig(LOCALNET_MANIFEST)
  return { config, client: createWorldClient({ config }) }
}

/** Sign as `sender` (default: admin), execute, assert success, and wait for the transaction to settle. */
export async function expectSuccess(
  client: WorldClient,
  transaction: Transaction,
  sender: Signer = keypair,
): Promise<ExecutedTransaction> {
  const result = await signAndExecute(client, { signer: sender, transaction })
  await client.waitForTransaction({ digest: result.digest })
  return result
}

/** Execute `transaction` sent by `sender` with the admin paying gas, i.e. an admin-sponsored transaction. */
export async function expectSponsored(
  client: WorldClient,
  transaction: Transaction,
  sender: Signer,
): Promise<void> {
  transaction.setSender(sender.toSuiAddress())
  transaction.setGasOwner(signer)
  const bytes = await transaction.build({ client })
  const signatures = await Promise.all(
    [sender, keypair].map(
      async (signer) => (await signer.signTransaction(bytes)).signature,
    ),
  )
  const result = await client.executeTransaction({
    transaction: bytes,
    signatures,
    include: { effects: true },
  })
  const { digest } = requireExecutedTx(result)
  await client.waitForTransaction({ digest })
}

/** Simulate `transaction` as `sender` and assert it aborts with a message matching `message`. */
export async function expectAbort(
  client: WorldClient,
  transaction: Transaction,
  sender: string,
  message: RegExp,
): Promise<void> {
  transaction.setSender(sender)
  const res = await client.simulateTransaction({ transaction })
  if (!res.FailedTransaction)
    throw new Error('expected the transaction to abort')
  expect(res.FailedTransaction.status.error?.message ?? '').toMatch(message)
}

type GenesisAlias = 'SPONSOR' | 'PLAYER_A' | 'PLAYER_B' | 'PLAYER_C'

const GENESIS_ACCOUNTS = fileURLToPath(
  new URL('../../../../docker/genesis/accounts.json', import.meta.url),
)

let genesisKeypairs: Record<GenesisAlias, Ed25519Keypair> | undefined

/** A genesis-funded localnet account. Already has SUI; no transfer needed. */
export function genesisAccount(alias: GenesisAlias): Ed25519Keypair {
  if (!genesisKeypairs) {
    const file = JSON.parse(readFileSync(GENESIS_ACCOUNTS, 'utf8')) as {
      accounts: Record<string, { privateKey?: string }>
    }
    const aliases = ['SPONSOR', 'PLAYER_A', 'PLAYER_B', 'PLAYER_C'] as const
    const loaded = {} as Record<GenesisAlias, Ed25519Keypair>
    for (const name of aliases) {
      const privateKey = file.accounts[name]?.privateKey
      if (!privateKey) {
        throw new Error(`accounts.json missing accounts.${name}.privateKey`)
      }
      loaded[name] = Ed25519Keypair.fromSecretKey(privateKey)
    }
    genesisKeypairs = loaded
  }
  return genesisKeypairs[alias]
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

/** Read the `type_id` balance of an entity's inventory via `balance_of` (simulate). */
export async function readBalance(
  client: WorldClient,
  config: WorldConfig,
  args: {
    entity: string
    componentId: bigint
    typeId: bigint
  },
): Promise<bigint> {
  const tx = new Transaction()
  tx.setSender(signer)
  balanceOf(tx, config, tx.object(args.entity), {
    componentId: args.componentId,
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

/** Fuel stats at `POWER_SCALE`, as the grid keeps them. */
export interface FuelStats {
  tenant: string
  fuelType: bigint
  impulse: bigint
  containmentBurden: bigint
  volatility: bigint
  thermalInefficiency?: bigint
}

/** `POWER_SCALE` stats times this are variant values at `VALUE_SCALE`. */
const STAT_TO_VALUE = 100_000n

/**
 * The fuel `Variant` with these stats in `tenant`, registered by the admin on
 * first use (one variant per set of stats, as in the game). Returns its object ID.
 */
export async function fuelVariant(
  client: WorldClient,
  config: WorldConfig,
  stats: FuelStats,
): Promise<string> {
  const thermal = stats.thermalInefficiency ?? 0n
  const mixed =
    ((stats.impulse * 1_000_003n + stats.containmentBurden) * 1_000_003n +
      stats.volatility) *
      1_000_003n +
    thermal
  const key = {
    tenant: stats.tenant,
    typeId: stats.fuelType,
    variantId: 1n + (mixed % 1_000_000_007n),
  }
  const id = deriveVariantId(config, key)
  const exists = await client
    .getObject({ objectId: id })
    .then(() => true)
    .catch(() => false)
  if (exists) return id
  const tx = new Transaction()
  registerVariant(tx, config, {
    key,
    kind: 'mass',
    unitVolume: 1n,
    values: [
      { propertyId: 208, magnitude: stats.impulse * STAT_TO_VALUE },
      { propertyId: 209, magnitude: thermal * STAT_TO_VALUE },
      { propertyId: 210, magnitude: stats.containmentBurden * STAT_TO_VALUE },
      { propertyId: 211, magnitude: stats.volatility * STAT_TO_VALUE },
    ],
  })
  await expectSuccess(client, tx)
  return id
}
