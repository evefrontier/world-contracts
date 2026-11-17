import { bcs } from '@mysten/sui/bcs'
import type { Transaction } from '@mysten/sui/transactions'
import { deriveObjectID } from '@mysten/sui/utils'
import { mvrName } from '../config/env.js'
import { adminAcl, killmailRegistry } from '../config/shared-objects.js'
import type { WorldConfig } from '../config/types.js'
import { deriveObjectId, type EntityKeyInput } from './core.js'

const KILLMAIL_PACKAGE = 'killmail'
const CORE_PACKAGE = 'core'

/** Must match `record::loss_type_from_u8` in Move (the game's proto LossType). */
export const LOSS_TYPE_SHIP = 1 as const
export const LOSS_TYPE_STRUCTURE = 2 as const

export type LossType = typeof LOSS_TYPE_SHIP | typeof LOSS_TYPE_STRUCTURE

export interface KillmailArgs {
  inGameId: bigint
  tenant: string
  reporterId: bigint
  killerId: bigint
  victimId: bigint
  lossType: LossType
  solarSystemId: bigint
  killTime: Date
}

/** Must match `core::entity_key::EntityKey` in Move. */
const EntityKey = bcs.struct('EntityKey', {
  id: bcs.u64(),
  tenant: bcs.string(),
})

/**
 * Deterministic object ID for a killmail, mirroring `killmail::registry::derive_id`
 * (a `derived_object` over `EntityKey{id, tenant}` on the `KillmailRegistry`).
 * Offline: needs the core package id, which only local/CI carry in `packageOverrides`.
 */
export function killmailObjectId(
  config: WorldConfig,
  key: EntityKeyInput,
): string {
  const coreId = config.packageOverrides?.[CORE_PACKAGE]
  if (!coreId) {
    throw new Error(
      `cannot derive killmail object id for env "${config.env}" offline: no core package id (only local/CI supply packageOverrides)`,
    )
  }
  const bytes = EntityKey.serialize(key).toBytes()
  const typeTag = `${coreId}::entity_key::EntityKey`
  return deriveObjectID(killmailRegistry(config).id, typeTag, bytes)
}

/** Unix seconds for `killTime`; Move stores `kill_timestamp` in seconds. */
function toUnixSeconds(killTime: Date): bigint {
  return BigInt(Math.floor(killTime.getTime() / 1000))
}

/**
 * Append `record::create_killmail` to `tx`: creates the killmail as a shared object
 * at its `KillmailRegistry`-derived id. The sender must be a sponsor on `AdminACL`,
 * and the reporter must be an existing character in the same tenant.
 */
export function createKillmail(
  tx: Transaction,
  config: WorldConfig,
  args: KillmailArgs,
): void {
  const registry = killmailRegistry(config)
  const acl = adminAcl(config)

  tx.moveCall({
    target: `${mvrName(config.env, KILLMAIL_PACKAGE)}::record::create_killmail`,
    arguments: [
      tx.sharedObjectRef({
        objectId: registry.id,
        initialSharedVersion: registry.initialSharedVersion ?? 0,
        mutable: true,
      }),
      tx.object(
        deriveObjectId(config, { id: args.reporterId, tenant: args.tenant }),
      ),
      tx.sharedObjectRef({
        objectId: acl.id,
        initialSharedVersion: acl.initialSharedVersion ?? 0,
        mutable: false,
      }),
      tx.pure.u64(args.inGameId),
      tx.pure.u64(args.killerId),
      tx.pure.u64(args.victimId),
      tx.pure.u64(toUnixSeconds(args.killTime)),
      tx.pure.u8(args.lossType),
      tx.pure.u64(args.solarSystemId),
    ],
  })
}
