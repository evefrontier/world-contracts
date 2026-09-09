import type {
  Transaction,
  TransactionArgument,
  TransactionResult,
} from '@mysten/sui/transactions'
import { mvrName } from '../config/env.js'
import type { WorldConfig } from '../config/types.js'
import { completeRequest, entityNew, shareEntity, verifyAdmin } from './core.js'

const INVENTORY_PACKAGE = 'inventory'

function pkg(config: WorldConfig): string {
  return mvrName(config.env, INVENTORY_PACKAGE)
}

export interface ItemRule {
  ephemeral: boolean
  typeId?: bigint | null
  minQuantity?: bigint | null
  maxQuantity?: bigint | null
}

function requirement(
  tx: Transaction,
  config: WorldConfig,
  fn: string,
  componentId: bigint,
  rule: ItemRule,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::inventory::${fn}`,
    arguments: [
      tx.pure.u64(componentId),
      tx.pure.bool(rule.ephemeral),
      tx.pure.option('u64', rule.typeId ?? null),
      tx.pure.option('u64', rule.minQuantity ?? null),
      tx.pure.option('u64', rule.maxQuantity ?? null),
    ],
  })
}

export function bridgeInRequirement(
  tx: Transaction,
  config: WorldConfig,
  componentId: bigint,
  rule: ItemRule,
): TransactionResult {
  return requirement(tx, config, 'bridge_in_requirement', componentId, rule)
}

export function bridgeOutRequirement(
  tx: Transaction,
  config: WorldConfig,
  componentId: bigint,
  rule: ItemRule,
): TransactionResult {
  return requirement(tx, config, 'bridge_out_requirement', componentId, rule)
}

export function depositRequirement(
  tx: Transaction,
  config: WorldConfig,
  componentId: bigint,
  rule: ItemRule,
): TransactionResult {
  return requirement(tx, config, 'deposit_requirement', componentId, rule)
}

export function withdrawRequirement(
  tx: Transaction,
  config: WorldConfig,
  componentId: bigint,
  rule: ItemRule,
): TransactionResult {
  return requirement(tx, config, 'withdraw_requirement', componentId, rule)
}

export interface InstallInventoryArgs {
  componentId: bigint
  typeId: bigint
  name?: string | null
  mainCapacity: bigint
  ephemeralCapacity: bigint
}

/** Install an inventory component on `entity` and close its admin-gated request. */
export function installInventory(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  args: InstallInventoryArgs,
): void {
  const request = tx.moveCall({
    target: `${pkg(config)}::inventory::install`,
    arguments: [
      entity,
      tx.pure.u64(args.componentId),
      tx.pure.u64(args.typeId),
      tx.pure.option('string', args.name ?? null),
      tx.pure.u64(args.mainCapacity),
      tx.pure.u64(args.ephemeralCapacity),
    ],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

/** Remove the inventory component `componentId`, closing its admin-gated request. */
export function uninstallInventory(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  componentId: bigint,
): void {
  const request = tx.moveCall({
    target: `${pkg(config)}::inventory::uninstall`,
    arguments: [entity, tx.pure.u64(componentId)],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

export interface CreateStorageUnitArgs {
  inGameId: bigint
  tenant: string
  componentId: bigint
  typeId: bigint
  name?: string | null
  mainCapacity: bigint
  ephemeralCapacity: bigint
}

/**
 * Claim an entity, install an inventory component, and share it — the full
 * storage-unit creation flow in one admin-signed transaction.
 */
export function createStorageUnit(
  tx: Transaction,
  config: WorldConfig,
  args: CreateStorageUnitArgs,
): void {
  const [entity, claimReq] = entityNew(tx, config, {
    inGameId: args.inGameId,
    tenant: args.tenant,
  })
  verifyAdmin(tx, config, claimReq)
  completeRequest(tx, config, entity, claimReq)
  installInventory(tx, config, entity, {
    componentId: args.componentId,
    typeId: args.typeId,
    name: args.name,
    mainCapacity: args.mainCapacity,
    ephemeralCapacity: args.ephemeralCapacity,
  })
  shareEntity(tx, config, entity)
}

export interface BalanceOfArgs {
  componentId: bigint
  authorizedId: string
  typeId: bigint
}

/**
 * Read the balance of `typeId` in the inventory routed to `authorizedId` (the
 * entity's own id for main, a caller's id for ephemeral). Read-only; run under
 * `simulateTransaction` and decode the returned `u64`.
 */
export function balanceOf(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  args: BalanceOfArgs,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::inventory::balance_of`,
    arguments: [
      entity,
      tx.pure.u64(args.componentId),
      tx.pure.address(args.authorizedId),
      tx.pure.u64(args.typeId),
    ],
  })
}

export interface BridgeInArgs {
  typeId: bigint
  quantity: bigint
  volume: bigint
}

/** Game-to-chain bridge: mint a balance into the caller's routed inventory. */
export function gameItemToChain(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  args: BridgeInArgs,
): void {
  tx.moveCall({
    target: `${pkg(config)}::inventory::game_item_to_chain_inventory`,
    arguments: [
      entity,
      request,
      tx.pure.u64(args.typeId),
      tx.pure.u64(args.quantity),
      tx.pure.u64(args.volume),
    ],
  })
}

export interface ItemAmount {
  typeId: bigint
  quantity: bigint
}

/** Chain-to-game bridge: burn a balance from the caller's routed inventory. */
export function chainItemToGame(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  args: ItemAmount,
): void {
  tx.moveCall({
    target: `${pkg(config)}::inventory::chain_item_to_game_inventory`,
    arguments: [
      entity,
      request,
      tx.pure.u64(args.typeId),
      tx.pure.u64(args.quantity),
    ],
  })
}

/** Deposit a standalone `Item` into the caller's routed inventory. */
export function deposit(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  item: TransactionArgument,
): void {
  tx.moveCall({
    target: `${pkg(config)}::inventory::deposit`,
    arguments: [entity, request, item],
  })
}

/** Withdraw a balance from the caller's routed inventory as a fresh `Item`. */
export function withdraw(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  args: ItemAmount,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::inventory::withdraw`,
    arguments: [
      entity,
      request,
      tx.pure.u64(args.typeId),
      tx.pure.u64(args.quantity),
    ],
  })
}
