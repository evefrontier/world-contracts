import { bcs } from '@mysten/sui/bcs'
import type {
  Transaction,
  TransactionArgument,
  TransactionResult,
} from '@mysten/sui/transactions'
import { deriveObjectID } from '@mysten/sui/utils'
import { mvrName } from '../config/env.js'
import { adminAcl, objectRegistry } from '../config/shared-objects.js'
import type { SharedObjectRef, WorldConfig } from '../config/types.js'

const CORE_PACKAGE = 'core'

/** Must match `core::entity_key::EntityKey` in Move. */
const ENTITY_KEY_MODULE = 'entity_key'
const ENTITY_KEY_STRUCT = 'EntityKey'

const EntityKey = bcs.struct(ENTITY_KEY_STRUCT, {
  id: bcs.u64(),
  tenant: bcs.string(),
})

export interface EntityKeyInput {
  id: bigint
  tenant: string
}

/**
 * Deterministic object ID for an entity, mirroring core
 * `object_registry::derive_id` (a `derived_object` over `EntityKey{id, tenant}`).
 * Offline: needs the core package id, which only local/CI carry in
 * `packageOverrides`.
 */
export function deriveObjectId(
  config: WorldConfig,
  key: EntityKeyInput,
): string {
  const coreId = config.packageOverrides?.[CORE_PACKAGE]
  if (!coreId) {
    throw new Error(
      `cannot derive object id for env "${config.env}" offline: no core package id (only local/CI supply packageOverrides)`,
    )
  }
  const registryId = objectRegistry(config).id
  const bytes = EntityKey.serialize({
    id: key.id,
    tenant: key.tenant,
  }).toBytes()
  const typeTag = `${coreId}::${ENTITY_KEY_MODULE}::${ENTITY_KEY_STRUCT}`
  return deriveObjectID(registryId, typeTag, bytes)
}

export interface EntityNewArgs {
  inGameId: bigint
  tenant: string
  locationHash?: number[]
}

/**
 * Claim a new entity. Returns `[entity, request]` handles; the request carries
 * an admin requirement that must be satisfied with `verifyAdmin` and closed with
 * `completeRequest` before the entity is configured.
 */
export function entityNew(
  tx: Transaction,
  config: WorldConfig,
  args: EntityNewArgs,
): TransactionResult {
  return tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::entity::new`,
    arguments: [
      sharedRef(tx, objectRegistry(config), true),
      tx.pure.u64(args.inGameId),
      tx.pure.string(args.tenant),
      tx.pure.vector('u8', args.locationHash ?? []),
    ],
  })
}

/** Satisfy an admin requirement on `request` against the shared `AdminACL`. */
export function verifyAdmin(
  tx: Transaction,
  config: WorldConfig,
  request: TransactionArgument,
): void {
  tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::admin_service::verify_admin`,
    arguments: [request, sharedRef(tx, adminAcl(config), false)],
  })
}

/** Close out a request against `entity`, unlocking it. */
export function completeRequest(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
): void {
  tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::entity::complete_request`,
    arguments: [entity, request],
  })
}

/** Share a configured entity. */
export function shareEntity(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
): void {
  tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::entity::share`,
    arguments: [entity],
  })
}

/** Add admins to the shared `AdminACL`. Signer must already be an admin. */
export function addAdmins(
  tx: Transaction,
  config: WorldConfig,
  admins: string[],
): void {
  tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::admin_service::add_admins`,
    arguments: [
      sharedRef(tx, adminAcl(config), true),
      tx.pure.vector('address', admins),
    ],
  })
}

/** Add sponsors to the shared `AdminACL`. Signer must already be an admin. */
export function addSponsors(
  tx: Transaction,
  config: WorldConfig,
  sponsors: string[],
): void {
  tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::admin_service::add_sponsors`,
    arguments: [
      sharedRef(tx, adminAcl(config), true),
      tx.pure.vector('address', sponsors),
    ],
  })
}

function sharedRef(tx: Transaction, ref: SharedObjectRef, mutable: boolean) {
  return tx.sharedObjectRef({
    objectId: ref.id,
    initialSharedVersion: ref.initialSharedVersion,
    mutable,
  })
}
