import type {
  Transaction,
  TransactionArgument,
  TransactionResult,
} from '@mysten/sui/transactions'
import { mvrName } from '../config/env.js'
import type { WorldConfig } from '../config/types.js'
import { completeRequest, verifyAdmin } from './core.js'
import {
  DESIRED_OFFLINE_MODULE,
  type ModulePowerSpec,
  migrateWith,
  modulePowerArguments,
} from './power.js'

const GENERIC_PACKAGE = 'generic_module'

function pkg(config: WorldConfig): string {
  return mvrName(config.env, GENERIC_PACKAGE)
}

export interface InstallGenericModuleArgs {
  componentId: bigint
  typeId: bigint
  name?: string | null
  data: Iterable<number>
  power?: ModulePowerSpec
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
      tx.pure.u64(args.componentId),
      tx.pure.u64(args.typeId),
      tx.pure.option('string', args.name ?? null),
      tx.pure.vector('u8', [...args.data]),
      ...modulePowerArguments(tx, config, args.power ?? DESIRED_OFFLINE_MODULE),
      tx.object.clock(),
    ],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

export function uninstallGenericModule(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  componentId: bigint,
): void {
  const request = tx.moveCall({
    target: `${pkg(config)}::generic_module::uninstall`,
    arguments: [entity, tx.pure.u64(componentId), tx.object.clock()],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

/** Move a generic module to `to` with its data and grid connection. Admin-gated. */
export function migrateGenericModule(
  tx: Transaction,
  config: WorldConfig,
  from: TransactionArgument,
  to: TransactionArgument,
  componentId: bigint,
): void {
  migrateWith(
    tx,
    config,
    `${pkg(config)}::generic_module::migrate`,
    from,
    to,
    componentId,
  )
}

export function genericModuleData(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  componentId: bigint,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::generic_module::data`,
    arguments: [entity, tx.pure.u64(componentId)],
  })
}

export function genericModuleTypeId(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  componentId: bigint,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::generic_module::type_id`,
    arguments: [entity, tx.pure.u64(componentId)],
  })
}

export function genericModuleName(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  componentId: bigint,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::generic_module::name`,
    arguments: [entity, tx.pure.u64(componentId)],
  })
}
