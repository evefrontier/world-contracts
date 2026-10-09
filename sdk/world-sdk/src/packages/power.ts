import type {
  Transaction,
  TransactionArgument,
  TransactionResult,
} from '@mysten/sui/transactions'
import { mvrName } from '../config/env.js'
import type { WorldConfig } from '../config/types.js'
import {
  completeRequest,
  verifyAdmin,
  verifyOwner,
  verifySponsor,
} from './core.js'

// Power, fuel and fuel stats are fixed point at `POWER_SCALE`: 0.1 MW = 1_000n.
export const POWER_SCALE = 10_000n

const POWER_PACKAGE = 'power'

function pkg(config: WorldConfig): string {
  return mvrName(config.env, POWER_PACKAGE)
}

type PowerModule = 'power_grid' | 'grid_fuel' | 'grid_generator' | 'grid_load'

function moveCallTarget(
  config: WorldConfig,
  moduleName: PowerModule,
  functionName: string,
): `${string}::${string}::${string}` {
  return `${pkg(config)}::${moduleName}::${functionName}`
}

function grid(
  config: WorldConfig,
  functionName: string,
): `${string}::${string}::${string}` {
  return moveCallTarget(config, 'power_grid', functionName)
}

export type DrawKind = 'firm' | 'elastic'

function drawKind(
  tx: Transaction,
  config: WorldConfig,
  kind: DrawKind,
): TransactionResult {
  return tx.moveCall({ target: grid(config, kind) })
}

/** Full type of the Inventory component, the module `connectModule` attaches. */
export function inventoryModuleType(config: WorldConfig): string {
  const inventoryPkg =
    config.packageOverrides?.inventory ?? mvrName(config.env, 'inventory')
  return `${inventoryPkg}::inventory::Inventory`
}

// === Install ===

/** Install the power grid (off, empty) and close its admin-gated request. */
export function installPowerGrid(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
): void {
  const request = tx.moveCall({
    target: grid(config, 'install'),
    arguments: [entity, tx.object.clock()],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

/** Install a Generator marker under `componentId` and close its admin-gated request. */
export function installGenerator(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  componentId: bigint,
  name: string | null = null,
): void {
  const request = tx.moveCall({
    target: `${pkg(config)}::generator::install`,
    arguments: [
      entity,
      tx.pure.u64(componentId),
      tx.pure.option('string', name),
    ],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

/** Install a Fuel bay marker under `componentId` and close its admin-gated request. */
export function installFuel(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  componentId: bigint,
  name: string | null = null,
): void {
  const request = tx.moveCall({
    target: `${pkg(config)}::fuel::install`,
    arguments: [
      entity,
      tx.pure.u64(componentId),
      tx.pure.option('string', name),
    ],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

// === Requirements ===

/**
 * Satisfied by `setPowerGrid`, `setGenerator`, `setPriority`, `reserve`, `release`
 * and `releasePriority`. Each handler also takes the owner's cap.
 */
export function operateGridRequirement(
  tx: Transaction,
  config: WorldConfig,
): TransactionResult {
  return tx.moveCall({ target: grid(config, 'operate_grid_requirement') })
}

/** Satisfied by `registerGenerator`. */
export function manageGeneratorRequirement(
  tx: Transaction,
  config: WorldConfig,
): TransactionResult {
  return tx.moveCall({ target: grid(config, 'manage_generator_requirement') })
}

/** Satisfied by `connectModule` / `disconnectModule`. */
export function manageModuleRequirement(
  tx: Transaction,
  config: WorldConfig,
): TransactionResult {
  return tx.moveCall({ target: grid(config, 'manage_module_requirement') })
}

/** Satisfied by `registerFuelSource`. */
export function manageFuelRequirement(
  tx: Transaction,
  config: WorldConfig,
): TransactionResult {
  return tx.moveCall({ target: grid(config, 'manage_fuel_requirement') })
}

/** The owner's rules for `depositFuel`. Omitted fields skip a check; values at `POWER_SCALE`. */
export interface FuelRule {
  fuelTypes?: bigint[]
  minImpulse?: bigint | null
  maxContainmentBurden?: bigint | null
  minAmount?: bigint | null
  maxAmount?: bigint | null
}

/** Satisfied by `depositFuel` when the deposit meets `rule`. */
export function depositFuelRequirement(
  tx: Transaction,
  config: WorldConfig,
  rule: FuelRule = {},
): TransactionResult {
  return tx.moveCall({
    target: grid(config, 'deposit_fuel_requirement'),
    arguments: [
      tx.pure.vector('u64', rule.fuelTypes ?? []),
      tx.pure.option('u64', rule.minImpulse ?? null),
      tx.pure.option('u64', rule.maxContainmentBurden ?? null),
      tx.pure.option('u64', rule.minAmount ?? null),
      tx.pure.option('u64', rule.maxAmount ?? null),
    ],
  })
}

/** Assertion: `moduleId` holds a reservation of `kind` with at least `draw` granted. */
export function reserveRequirement(
  tx: Transaction,
  config: WorldConfig,
  moduleId: bigint,
  draw: bigint,
  kind: DrawKind,
): TransactionResult {
  return tx.moveCall({
    target: grid(config, 'reserve_requirement'),
    arguments: [
      tx.pure.u64(moduleId),
      tx.pure.u64(draw),
      drawKind(tx, config, kind),
    ],
  })
}

// === Handlers (satisfy the next requirement on `request`) ===

export interface RegisterGeneratorArgs {
  generatorId: bigint
  maxOutputMw: bigint
  containmentReduction: bigint
  baseFuelRate: bigint
}

/** Register a Generator with its stats. Satisfies the admin follow-up too. */
export function registerGenerator(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  args: RegisterGeneratorArgs,
): void {
  tx.moveCall({
    target: moveCallTarget(config, 'grid_generator', 'register_generator'),
    arguments: [
      entity,
      request,
      tx.pure.u64(args.generatorId),
      tx.pure.u64(args.maxOutputMw),
      tx.pure.u64(args.containmentReduction),
      tx.pure.u64(args.baseFuelRate),
      tx.object.clock(),
    ],
  })
  verifyAdmin(tx, config, request)
}

/** Register a Fuel source with its capacity. Satisfies the admin follow-up too. */
export function registerFuelSource(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  fuelId: bigint,
  capacity: bigint,
): void {
  tx.moveCall({
    target: moveCallTarget(config, 'grid_fuel', 'register_fuel_source'),
    arguments: [
      entity,
      request,
      tx.pure.u64(fuelId),
      tx.pure.u64(capacity),
      tx.object.clock(),
    ],
  })
  verifyAdmin(tx, config, request)
}

/**
 * Connect a module with its line loss. `moduleType` is the installed component's
 * full type, e.g. `${inventoryPkg}::inventory::Inventory`. Satisfies the admin follow-up too.
 */
export function connectModule(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  moduleId: bigint,
  lineLoss: bigint,
  moduleType: string,
): void {
  tx.moveCall({
    target: moveCallTarget(config, 'grid_load', 'connect_module'),
    typeArguments: [moduleType],
    arguments: [
      entity,
      request,
      tx.pure.u64(moduleId),
      tx.pure.u64(lineLoss),
      tx.object.clock(),
    ],
  })
  verifyAdmin(tx, config, request)
}

export interface DepositFuelArgs {
  fuelType: bigint
  amount: bigint
  impulse: bigint
  containmentBurden: bigint
}

/**
 * Bridge fuel into the pool. The owner's `ownerCap` authorizes the deposit, and
 * the gas sponsor must be on `AdminACL`.
 */
export function depositFuel(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  ownerCap: string | TransactionArgument,
  args: DepositFuelArgs,
): void {
  tx.moveCall({
    target: moveCallTarget(config, 'grid_fuel', 'deposit_fuel'),
    arguments: [
      entity,
      request,
      tx.pure.u64(args.fuelType),
      tx.pure.u64(args.amount),
      tx.pure.u64(args.impulse),
      tx.pure.u64(args.containmentBurden),
      tx.object.clock(),
    ],
  })
  verifyOwner(tx, config, request, ownerCap)
  verifySponsor(tx, config, request)
}

/** Switch the grid on or off. Owner-gated. */
export function setPowerGrid(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  ownerCap: string | TransactionArgument,
  on: boolean,
): void {
  tx.moveCall({
    target: grid(config, 'set_power_grid'),
    arguments: [entity, request, tx.pure.bool(on), tx.object.clock()],
  })
  verifyOwner(tx, config, request, ownerCap)
}

/** Bring a Generator online or offline. Offline sheds what no longer fits. Owner-gated. */
export function setGenerator(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  ownerCap: string | TransactionArgument,
  generatorId: bigint,
  online: boolean,
): void {
  tx.moveCall({
    target: moveCallTarget(config, 'grid_generator', 'set_generator'),
    arguments: [
      entity,
      request,
      tx.pure.u64(generatorId),
      tx.pure.bool(online),
      tx.object.clock(),
    ],
  })
  verifyOwner(tx, config, request, ownerCap)
}

/** Disconnect a module, releasing its reservation. Satisfies the admin follow-up too. */
export function disconnectModule(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  moduleId: bigint,
): void {
  tx.moveCall({
    target: moveCallTarget(config, 'grid_load', 'disconnect_module'),
    arguments: [entity, request, tx.pure.u64(moduleId), tx.object.clock()],
  })
  verifyAdmin(tx, config, request)
}

/** Reserve `draw` for `moduleId`. Aborts if it does not fit. Owner-gated. */
export function reserve(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  ownerCap: string | TransactionArgument,
  moduleId: bigint,
  draw: bigint,
  kind: DrawKind,
): void {
  tx.moveCall({
    target: moveCallTarget(config, 'grid_load', 'reserve'),
    arguments: [
      entity,
      request,
      tx.pure.u64(moduleId),
      tx.pure.u64(draw),
      drawKind(tx, config, kind),
      tx.object.clock(),
    ],
  })
  verifyOwner(tx, config, request, ownerCap)
}

/** Move a connected module into priority group `priority`. Higher groups are shed first. Owner-gated. */
export function setPriority(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  ownerCap: string | TransactionArgument,
  moduleId: bigint,
  priority: bigint,
): void {
  tx.moveCall({
    target: moveCallTarget(config, 'grid_load', 'set_priority'),
    arguments: [
      entity,
      request,
      tx.pure.u64(moduleId),
      tx.pure.u64(priority),
      tx.object.clock(),
    ],
  })
  verifyOwner(tx, config, request, ownerCap)
}

/** Release every reservation in priority group `priority`. Owner-gated. */
export function releasePriority(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  ownerCap: string | TransactionArgument,
  priority: bigint,
): void {
  tx.moveCall({
    target: moveCallTarget(config, 'grid_load', 'release_priority'),
    arguments: [entity, request, tx.pure.u64(priority), tx.object.clock()],
  })
  verifyOwner(tx, config, request, ownerCap)
}

/** Release `moduleId`'s reservation. Owner-gated. */
export function release(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  ownerCap: string | TransactionArgument,
  moduleId: bigint,
): void {
  tx.moveCall({
    target: moveCallTarget(config, 'grid_load', 'release'),
    arguments: [entity, request, tx.pure.u64(moduleId), tx.object.clock()],
  })
  verifyOwner(tx, config, request, ownerCap)
}

/** Satisfy a `reserveRequirement`: the module is still powered and the grid still has fuel. */
export function assertReserved(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
): void {
  tx.moveCall({
    target: moveCallTarget(config, 'grid_load', 'assert_reserved'),
    arguments: [entity, request, tx.object.clock()],
  })
}
