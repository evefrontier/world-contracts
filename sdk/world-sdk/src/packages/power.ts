import type {
  Transaction,
  TransactionArgument,
  TransactionResult,
} from '@mysten/sui/transactions'
import { mvrName } from '../config/env.js'
import type { WorldConfig } from '../config/types.js'
import { completeRequest, verifyAdmin, verifySponsor } from './core.js'

// Power, fuel and fuel stats are fixed point at `POWER_SCALE`: 0.1 MW = 1_000n.
export const POWER_SCALE = 10_000n

const POWER_PACKAGE = 'power'

function pkg(config: WorldConfig): string {
  return mvrName(config.env, POWER_PACKAGE)
}

function grid(
  config: WorldConfig,
  fn: string,
): `${string}::${string}::${string}` {
  return `${pkg(config)}::power_grid::${fn}`
}

export type DrawKind = 'firm' | 'elastic'

function drawKind(
  tx: Transaction,
  config: WorldConfig,
  kind: DrawKind,
): TransactionResult {
  return tx.moveCall({ target: grid(config, kind) })
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

/** Satisfied by `setPowerGrid`, `setGenerator`, `setPriority`, `reserve` and `release`. */
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
    target: grid(config, 'register_generator'),
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
    target: grid(config, 'register_fuel_source'),
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

/** Connect a module with its line loss. Satisfies the admin follow-up too. */
export function connectModule(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  moduleId: bigint,
  lineLoss: bigint,
): void {
  tx.moveCall({
    target: grid(config, 'connect_module'),
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

/** Bridge fuel into the pool. The gas sponsor must be on `AdminACL`. */
export function depositFuel(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  args: DepositFuelArgs,
): void {
  tx.moveCall({
    target: grid(config, 'deposit_fuel'),
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
  verifySponsor(tx, config, request)
}

/** Switch the grid on or off. */
export function setPowerGrid(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  on: boolean,
): void {
  tx.moveCall({
    target: grid(config, 'set_power_grid'),
    arguments: [entity, request, tx.pure.bool(on), tx.object.clock()],
  })
}

/** Bring a Generator online or offline. Offline sheds what no longer fits. */
export function setGenerator(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  generatorId: bigint,
  online: boolean,
): void {
  tx.moveCall({
    target: grid(config, 'set_generator'),
    arguments: [
      entity,
      request,
      tx.pure.u64(generatorId),
      tx.pure.bool(online),
      tx.object.clock(),
    ],
  })
}

/** Reserve `draw` for `moduleId`. Aborts if it does not fit. */
export function reserve(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  moduleId: bigint,
  draw: bigint,
  kind: DrawKind,
): void {
  tx.moveCall({
    target: grid(config, 'reserve'),
    arguments: [
      entity,
      request,
      tx.pure.u64(moduleId),
      tx.pure.u64(draw),
      drawKind(tx, config, kind),
      tx.object.clock(),
    ],
  })
}

/** Release `moduleId`'s reservation. */
export function release(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  moduleId: bigint,
): void {
  tx.moveCall({
    target: grid(config, 'release'),
    arguments: [entity, request, tx.pure.u64(moduleId), tx.object.clock()],
  })
}

/** Satisfy a `reserveRequirement`: the module is still powered and the grid still has fuel. */
export function assertReserved(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
): void {
  tx.moveCall({
    target: grid(config, 'assert_reserved'),
    arguments: [entity, request, tx.object.clock()],
  })
}
