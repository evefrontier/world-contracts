import { bcs } from '@mysten/sui/bcs'
import type {
  Transaction,
  TransactionArgument,
  TransactionResult,
} from '@mysten/sui/transactions'
import { deriveObjectID } from '@mysten/sui/utils'
import { mvrName } from '../config/env.js'
import { variantRegistry } from '../config/shared-objects.js'
import type { WorldConfig } from '../config/types.js'
import { verifyAdmin } from './core.js'

// Property values and mass quantities are fixed point at 1e9 (the proto's nanos).
export const VALUE_SCALE = 1_000_000_000n
/** Base units per kg of a `mass` variant. */
export const MASS_UNIT = VALUE_SCALE

const VARIANT_PACKAGE = 'variant'

/** Must match `variant::variant::VariantKey` in Move. */
const VariantKey = bcs.struct('VariantKey', {
  tenant: bcs.string(),
  type_id: bcs.u64(),
  variant_id: bcs.u64(),
})

export interface VariantKeyInput {
  tenant: string
  typeId: bigint
  /** The game's variant ID; `0n` for a type with no variant. */
  variantId: bigint
}

export type QuantityKind = 'units' | 'mass'

/** A signed property value at `VALUE_SCALE`. */
export interface PropertyValue {
  propertyId: number
  magnitude: bigint
  negative?: boolean
}

export interface RegisterVariantArgs {
  key: VariantKeyInput
  kind: QuantityKind
  /**
   * m³ per kg (`mass`, i.e. 1 / the variant's density) or per item (`units`), at
   * `VALUE_SCALE`. Must be non-zero.
   */
  unitVolume: bigint
  /** Any order; sorted ascending by `propertyId` here. */
  values: PropertyValue[]
}

function target(
  config: WorldConfig,
  fn: string,
): `${string}::${string}::${string}` {
  return `${mvrName(config.env, VARIANT_PACKAGE)}::variant::${fn}`
}

function kindCall(
  tx: Transaction,
  config: WorldConfig,
  kind: QuantityKind,
): TransactionResult {
  return tx.moveCall({ target: target(config, kind) })
}

/**
 * Object ID a variant has, or will have, under `key`, mirroring
 * `variant::derive_id`. Offline: needs the variant package id, which only
 * local/CI carry in `packageOverrides`.
 */
export function deriveVariantId(
  config: WorldConfig,
  key: VariantKeyInput,
): string {
  const variantPkg = config.packageOverrides?.[VARIANT_PACKAGE]
  if (!variantPkg) {
    throw new Error(
      `cannot derive variant id for env "${config.env}" offline: no variant package id (only local/CI supply packageOverrides)`,
    )
  }
  const bytes = VariantKey.serialize({
    tenant: key.tenant,
    type_id: key.typeId,
    variant_id: key.variantId,
  }).toBytes()
  return deriveObjectID(
    variantRegistry(config).id,
    `${variantPkg}::variant::VariantKey`,
    bytes,
  )
}

/**
 * Register a variant's values and freeze the record: `register`, then the
 * admin check, then `complete_registration`. The sender must be an admin. The
 * record can only be read in a later transaction.
 */
export function registerVariant(
  tx: Transaction,
  config: WorldConfig,
  args: RegisterVariantArgs,
): void {
  const values = [...args.values].sort((a, b) => a.propertyId - b.propertyId)
  const registry = variantRegistry(config)
  const [record, request] = tx.moveCall({
    target: target(config, 'register'),
    arguments: [
      tx.sharedObjectRef({
        objectId: registry.id,
        initialSharedVersion: registry.initialSharedVersion ?? 0,
        mutable: true,
      }),
      tx.pure.string(args.key.tenant),
      tx.pure.u64(args.key.typeId),
      tx.pure.u64(args.key.variantId),
      kindCall(tx, config, args.kind),
      tx.pure.u64(args.unitVolume),
      tx.pure.vector(
        'u32',
        values.map((v) => v.propertyId),
      ),
      tx.pure.vector(
        'u128',
        values.map((v) => v.magnitude),
      ),
      tx.pure.vector(
        'bool',
        values.map((v) => v.negative ?? false),
      ),
    ],
  })
  verifyAdmin(tx, config, request as TransactionArgument)
  tx.moveCall({
    target: target(config, 'complete_registration'),
    arguments: [record as TransactionArgument, request as TransactionArgument],
  })
}
