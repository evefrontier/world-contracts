import { bcs } from '@mysten/sui/bcs'
import type { Transaction, TransactionArgument } from '@mysten/sui/transactions'
import { deriveObjectID } from '@mysten/sui/utils'
import { mvrName } from '../config/env.js'
import { killmailRegistry } from '../config/shared-objects.js'
import type { WorldConfig } from '../config/types.js'
import { deriveObjectId, verifySponsor } from './core.js'

const KILLMAIL_PACKAGE = 'killmail'

/** Must match `record::loss_type_from_u8` in Move (the game's proto LossType). */
export const LOSS_TYPE_SHIP = 1 as const
export const LOSS_TYPE_STRUCTURE = 2 as const

export type LossType = typeof LOSS_TYPE_SHIP | typeof LOSS_TYPE_STRUCTURE

export interface KillmailArgs {
  /** The game's killmail id; with the reporter's tenant, the killmail's `KillmailKey`. */
  inGameId: bigint
  tenant: string
  reporterId: bigint
  killerId: bigint
  victimId: bigint
  lossType: LossType
  solarSystemId: bigint
  killTime: Date
}

/** Must match `killmail::registry::KillmailKey` in Move. */
const KillmailKey = bcs.struct('KillmailKey', {
  tenant: bcs.string(),
  killmail_id: bcs.u64(),
})

export interface KillmailKeyInput {
  tenant: string
  /** The game's killmail id. Must be non-zero. */
  killmailId: bigint
}

/**
 * Object ID a killmail has, or will have, under `key`, mirroring
 * `killmail::registry::derive_id`. Offline: needs the killmail package id, which
 * only local/CI carry in `packageOverrides`.
 */
export function killmailObjectId(
  config: WorldConfig,
  key: KillmailKeyInput,
): string {
  const killmailPkg = config.packageOverrides?.[KILLMAIL_PACKAGE]
  if (!killmailPkg) {
    throw new Error(
      `cannot derive killmail object id for env "${config.env}" offline: no killmail package id (only local/CI supply packageOverrides)`,
    )
  }
  const bytes = KillmailKey.serialize({
    tenant: key.tenant,
    killmail_id: key.killmailId,
  }).toBytes()
  return deriveObjectID(
    killmailRegistry(config).id,
    `${killmailPkg}::registry::KillmailKey`,
    bytes,
  )
}

/** Unix seconds for `killTime`; Move stores `kill_timestamp` in seconds. */
function toUnixSeconds(killTime: Date): bigint {
  return BigInt(Math.floor(killTime.getTime() / 1000))
}

function target(
  config: WorldConfig,
  fn: string,
): `${string}::${string}::${string}` {
  return `${mvrName(config.env, KILLMAIL_PACKAGE)}::record::${fn}`
}

/**
 * Create a killmail and share it at its `KillmailRegistry`-derived id:
 * `create_killmail`, then the sponsor check, then `complete_killmail`. The gas
 * sponsor (or the sender, when unsponsored) must be a sponsor on `AdminACL`, and
 * the reporter must be an existing character; the killmail takes its tenant. The
 * record can only be read in a later transaction.
 */
export function createKillmail(
  tx: Transaction,
  config: WorldConfig,
  args: KillmailArgs,
): void {
  const registry = killmailRegistry(config)
  const [record, request] = tx.moveCall({
    target: target(config, 'create_killmail'),
    arguments: [
      tx.sharedObjectRef({
        objectId: registry.id,
        initialSharedVersion: registry.initialSharedVersion ?? 0,
        mutable: true,
      }),
      tx.object(
        deriveObjectId(config, { id: args.reporterId, tenant: args.tenant }),
      ),
      tx.pure.u64(args.inGameId),
      tx.pure.u64(args.killerId),
      tx.pure.u64(args.victimId),
      tx.pure.u64(toUnixSeconds(args.killTime)),
      tx.pure.u8(args.lossType),
      tx.pure.u64(args.solarSystemId),
    ],
  })
  verifySponsor(tx, config, request as TransactionArgument)
  tx.moveCall({
    target: target(config, 'complete_killmail'),
    arguments: [record as TransactionArgument, request as TransactionArgument],
  })
}
