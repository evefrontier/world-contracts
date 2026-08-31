import { bcs } from '@mysten/sui/bcs'
import type {
  Transaction,
  TransactionArgument,
  TransactionObjectArgument,
  TransactionResult,
} from '@mysten/sui/transactions'
import { deriveObjectID } from '@mysten/sui/utils'
import { mvrName } from '../config/env.js'
import { adminAcl, objectRegistry } from '../config/shared-objects.js'
import type { SharedObjectRef, WorldConfig } from '../config/types.js'

const CORE_PACKAGE = 'core'

function requirementTypeTag(config: WorldConfig): string {
  const prefix =
    config.packageOverrides?.[CORE_PACKAGE] ?? mvrName(config.env, CORE_PACKAGE)
  return `${prefix}::requirement::Requirement`
}

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

/**
 * Delete an entity with no modules left. Uninstall every module first.
 */
export function deleteEntity(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
): void {
  tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::entity::delete`,
    arguments: [entity, sharedRef(tx, adminAcl(config), false)],
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

export interface MintAccessArgs {
  entity: string
  owner: string
  transferable: boolean
}

/**
 * Mint an `AccessCap` for an already-shared entity and grant it to `owner`. A
 * second-transaction flow (the entity must already be shared): mints, satisfies
 * the admin requirement, and closes the request. Signer must be an admin.
 */
export function mintAccess(
  tx: Transaction,
  config: WorldConfig,
  args: MintAccessArgs,
): void {
  const entity = tx.object(args.entity)
  const request = tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::entity::mint_access`,
    arguments: [
      entity,
      tx.pure.address(args.owner),
      tx.pure.bool(args.transferable),
    ],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

/** Build a caller requirement: satisfied by any valid `AccessCap`, recording its holder. */
export function callerRequirement(
  tx: Transaction,
  config: WorldConfig,
): TransactionResult {
  return tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::access_cap::caller_requirement`,
  })
}

/** Build an owner requirement: satisfied only by the target entity's own `AccessCap`. */
export function ownerRequirement(
  tx: Transaction,
  config: WorldConfig,
): TransactionResult {
  return tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::access_cap::owner_requirement`,
  })
}

/** Satisfy an owner requirement on `request` by presenting the entity's `AccessCap`. */
export function verifyOwner(
  tx: Transaction,
  config: WorldConfig,
  request: TransactionArgument,
  cap: string | TransactionArgument,
): void {
  tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::access_cap::verify`,
    arguments: [request, capArg(tx, cap)],
  })
}

/**
 * Satisfy a caller requirement on `request` with any valid `AccessCap`, recording
 * its entity as the request actor (drives inventory owner-vs-ephemeral routing).
 */
export function verifyCaller(
  tx: Transaction,
  config: WorldConfig,
  request: TransactionArgument,
  cap: string | TransactionArgument,
): void {
  tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::access_cap::verify_caller`,
    arguments: [request, capArg(tx, cap)],
  })
}

/** Satisfy a proximity requirement. `callerLocationHash` must match the target baked at `interact`. */
export function verifyProximity(
  tx: Transaction,
  config: WorldConfig,
  request: TransactionArgument,
  callerLocationHash: number[],
): void {
  tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::location_service::verify_proximity`,
    arguments: [request, tx.pure.vector('u8', callerLocationHash)],
  })
}

/** Open an interaction with a registered action, returning the `Request` to satisfy. */
export function interact(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  action: string,
  targetLocationHash: number[],
): TransactionResult {
  return tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::entity::interact`,
    arguments: [
      entity,
      tx.pure.string(action),
      tx.pure.vector('u8', targetLocationHash),
    ],
  })
}

/**
 * Expose an action under `name` from `requirements` and close its owner-gated
 * request with `ownerCap`. Requirements resolve in the order given.
 */
export function enableAction(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  name: string,
  requirements: TransactionObjectArgument[],
  ownerCap: string | TransactionArgument,
): void {
  const core = mvrName(config.env, CORE_PACKAGE)
  const requirementType = requirementTypeTag(config)
  const action = tx.moveCall({
    target: `${core}::action::new`,
    arguments: [
      tx.makeMoveVec({
        type: requirementType,
        elements: requirements,
      }),
    ],
  })
  const request = tx.moveCall({
    target: `${core}::entity::enable_action`,
    arguments: [entity, tx.pure.string(name), action],
  })
  verifyOwner(tx, config, request, ownerCap)
  completeRequest(tx, config, entity, request)
}

/** Remove a previously-exposed action, closing its owner-gated request. */
export function disableAction(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  name: string,
  ownerCap: string | TransactionArgument,
): void {
  const request = tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::entity::disable_action`,
    arguments: [entity, tx.pure.string(name)],
  })
  verifyOwner(tx, config, request, ownerCap)
  completeRequest(tx, config, entity, request)
}

export interface CapObjectRef {
  objectId: string
  version: string | number
  digest: string
}

/**
 * Borrow an `AccessCap` parked on `character`, presenting `entityCap` (the
 * character's own cap). `cap` is the parked cap's current object ref (fetch it
 * fresh — its version changes each borrow/return). Returns the `[cap, receipt]`
 * tuple; pass both to `returnAccess` (or the cap+receipt to
 * `access_cap::transfer_with_receipt`) before the transaction ends.
 */
export function borrowAccess(
  tx: Transaction,
  config: WorldConfig,
  character: TransactionArgument,
  entityCap: string | TransactionArgument,
  cap: CapObjectRef,
): TransactionResult {
  return tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::entity::borrow_access`,
    arguments: [character, capArg(tx, entityCap), tx.receivingRef(cap)],
  })
}

/** Put a borrowed cap back on `character`, consuming its receipt. */
export function returnAccess(
  tx: Transaction,
  config: WorldConfig,
  character: TransactionArgument,
  cap: TransactionArgument,
  receipt: TransactionArgument,
): void {
  tx.moveCall({
    target: `${mvrName(config.env, CORE_PACKAGE)}::entity::return_access`,
    arguments: [character, cap, receipt],
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

function capArg(tx: Transaction, cap: string | TransactionArgument) {
  return typeof cap === 'string' ? tx.object(cap) : cap
}

function sharedRef(
  tx: Transaction,
  ref: Pick<SharedObjectRef, 'id' | 'initialSharedVersion'>,
  mutable: boolean,
) {
  return tx.sharedObjectRef({
    objectId: ref.id,
    initialSharedVersion: ref.initialSharedVersion ?? 0,
    mutable,
  })
}
