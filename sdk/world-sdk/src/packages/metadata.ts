import type {
  Transaction,
  TransactionArgument,
  TransactionResult,
} from '@mysten/sui/transactions'
import { mvrName } from '../config/env.js'
import type { WorldConfig } from '../config/types.js'
import { completeRequest, verifyAdmin } from './core.js'

const METADATA_PACKAGE = 'metadata'

function pkg(config: WorldConfig): string {
  return mvrName(config.env, METADATA_PACKAGE)
}

export interface MetadataFields {
  name: string
  description: string
  url: string
}

export interface InstallMetadataArgs extends MetadataFields {
  typeId: bigint
}

/** Install metadata on `entity` and close its admin-gated request. */
export function installMetadata(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  fields: InstallMetadataArgs,
): void {
  const request = tx.moveCall({
    target: `${pkg(config)}::metadata::install`,
    arguments: [
      entity,
      tx.pure.u64(fields.typeId),
      tx.pure.string(fields.name),
      tx.pure.string(fields.description),
      tx.pure.string(fields.url),
    ],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

/** Remove metadata from `entity`, closing its admin-gated request. */
export function uninstallMetadata(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
): void {
  const request = tx.moveCall({
    target: `${pkg(config)}::metadata::uninstall`,
    arguments: [entity],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

/** Build an edit requirement targeting the metadata module slot. */
export function editRequirement(
  tx: Transaction,
  config: WorldConfig,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::metadata::edit_requirement`,
    arguments: [],
  })
}

/** Replace all metadata fields while satisfying the next `Edit` requirement. */
export function editMetadata(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  fields: MetadataFields,
): void {
  tx.moveCall({
    target: `${pkg(config)}::metadata::edit`,
    arguments: [
      entity,
      request,
      tx.pure.string(fields.name),
      tx.pure.string(fields.description),
      tx.pure.string(fields.url),
    ],
  })
}
