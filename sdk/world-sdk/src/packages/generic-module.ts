import type {
  Transaction,
  TransactionArgument,
  TransactionResult,
} from '@mysten/sui/transactions'
import { mvrName } from '../config/env.js'
import type { WorldConfig } from '../config/types.js'
import { completeRequest, verifyAdmin } from './core.js'

const CORE_PACKAGE = 'core'

function pkg(config: WorldConfig): string {
  return mvrName(config.env, CORE_PACKAGE)
}

export interface InstallGenericModuleArgs {
  moduleId: bigint
  typeId: bigint
  name?: string | null
  data: Iterable<number>
}

export function installGenericModule(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  args: InstallGenericModuleArgs,
): void {
  const request = tx.moveCall({
    target: `${pkg(config)}::generic_module::install`,
    arguments: [
      entity,
      tx.pure.u64(args.moduleId),
      tx.pure.u64(args.typeId),
      tx.pure.option('string', args.name ?? null),
      tx.pure.vector('u8', [...args.data]),
    ],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

export function uninstallGenericModule(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  moduleId: bigint,
): void {
  const request = tx.moveCall({
    target: `${pkg(config)}::generic_module::uninstall`,
    arguments: [entity, tx.pure.u64(moduleId)],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

export function genericModuleData(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  moduleId: bigint,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::generic_module::data`,
    arguments: [entity, tx.pure.u64(moduleId)],
  })
}

export function genericModuleTypeId(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  moduleId: bigint,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::generic_module::type_id`,
    arguments: [entity, tx.pure.u64(moduleId)],
  })
}

export function genericModuleName(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  moduleId: bigint,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::generic_module::name`,
    arguments: [entity, tx.pure.u64(moduleId)],
  })
}
