import type {
  Transaction,
  TransactionArgument,
  TransactionResult,
} from '@mysten/sui/transactions'
import { mvrName } from '../config/env.js'
import type { WorldConfig } from '../config/types.js'

const FREIGHT_PACKAGE = 'freight'

function pkg(config: WorldConfig): string {
  return mvrName(config.env, FREIGHT_PACKAGE)
}

/**
 * Build a pickup requirement that authorizes delivery to `destination`
 * (entity object id).
 */
export function pickupRequirement(
  tx: Transaction,
  config: WorldConfig,
  destination: string,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::freight::pickup_requirement`,
    arguments: [tx.pure.address(destination)],
  })
}

/** Build a dropoff requirement that consumes a matching `FreightReceipt`. */
export function dropoffRequirement(
  tx: Transaction,
  config: WorldConfig,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::freight::dropoff_requirement`,
  })
}

/**
 * Issue a `FreightReceipt` binding `item` to this source entity and the
 * destination configured on the pickup requirement. Call after `withdraw` in
 * the same request. Returns the receipt object.
 */
export function pickup(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  item: TransactionArgument,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::freight::pickup`,
    arguments: [entity, request, item],
  })
}

/**
 * Validate and consume `receipt` against this destination, the authorized
 * carrier, and the exact `item`. Call before `deposit` in the same request.
 */
export function dropoff(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  item: TransactionArgument,
  receipt: TransactionArgument,
): void {
  tx.moveCall({
    target: `${pkg(config)}::freight::dropoff`,
    arguments: [entity, request, item, receipt],
  })
}
