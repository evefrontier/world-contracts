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

function drawKindCall(
  tx: Transaction,
  config: WorldConfig,
  drawKind: DrawKind,
): TransactionResult {
  return tx.moveCall({ target: grid(config, drawKind) })
}

export interface ModulePowerSpec {
  powerReq: bigint
  drawKind?: DrawKind
  priority?: bigint
  lineLoss?: bigint
}

/** A module that connects to the grid but stays desired-offline until the owner turns it on. */
export const DESIRED_OFFLINE_MODULE: ModulePowerSpec = {
  powerReq: 1n,
  drawKind: 'firm',
  priority: 0n,
  lineLoss: 0n,
}

export function modulePowerArguments(
  tx: Transaction,
  config: WorldConfig,
  spec: ModulePowerSpec,
): TransactionArgument[] {
  return [
    tx.pure.u64(spec.powerReq),
    drawKindCall(tx, config, spec.drawKind ?? 'firm'),
    tx.moveCall({ target: grid(config, 'power') }),
    tx.pure.u64(spec.priority ?? 0n),
    tx.pure.u64(spec.lineLoss ?? 0n),
  ]
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

/** Remove the grid. Aborts while a module, generator, or fuel source is still connected. */
export function uninstallPowerGrid(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
): void {
  const request = tx.moveCall({
    target: grid(config, 'uninstall'),
    arguments: [entity],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

export interface InstallGeneratorArgs {
  componentId: bigint
  name?: string | null
  maxOutputMw: bigint
  containmentReduction: bigint
  baseFuelRate: bigint
}

/** Install a Generator and connect it to the grid, offline. Admin-gated. */
export function installGenerator(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  args: InstallGeneratorArgs,
): void {
  const request = tx.moveCall({
    target: moveCallTarget(config, 'grid_generator', 'install'),
    arguments: [
      entity,
      tx.pure.u64(args.componentId),
      tx.pure.option('string', args.name ?? null),
      tx.pure.u64(args.maxOutputMw),
      tx.pure.u64(args.containmentReduction),
      tx.pure.u64(args.baseFuelRate),
      tx.object.clock(),
    ],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

export interface InstallFuelArgs {
  componentId: bigint
  name?: string | null
  capacity: bigint
}

/** Install a Fuel source and add its capacity to the grid. Admin-gated. */
export function installFuel(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  args: InstallFuelArgs,
): void {
  const request = tx.moveCall({
    target: moveCallTarget(config, 'grid_fuel', 'install'),
    arguments: [
      entity,
      tx.pure.u64(args.componentId),
      tx.pure.option('string', args.name ?? null),
      tx.pure.u64(args.capacity),
      tx.object.clock(),
    ],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

/** Remove a Generator and its output from the grid. Admin-gated. */
export function uninstallGenerator(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  componentId: bigint,
): void {
  const request = tx.moveCall({
    target: moveCallTarget(config, 'grid_generator', 'uninstall'),
    arguments: [entity, tx.pure.u64(componentId), tx.object.clock()],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

/**
 * Remove a Fuel source. It takes its share of the pool with it; the returned
 * `FuelLoad` can go straight into `installFuelWithLoad` later in the PTB.
 * Admin-gated.
 */
export function uninstallFuel(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  componentId: bigint,
): TransactionArgument {
  const [request, load] = tx.moveCall({
    target: moveCallTarget(config, 'grid_fuel', 'uninstall'),
    arguments: [entity, tx.pure.u64(componentId), tx.object.clock()],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
  return load
}

export interface FuelLoadArgs {
  amount: bigint
  impulse: bigint
  containmentBurden: bigint
}

/** Build a `FuelLoad`, e.g. from a `FuelSourceDisconnected` event read earlier. */
export function fuelLoad(
  tx: Transaction,
  config: WorldConfig,
  args: FuelLoadArgs,
): TransactionResult {
  return tx.moveCall({
    target: moveCallTarget(config, 'grid_fuel', 'fuel_load'),
    arguments: [
      tx.pure.u64(args.amount),
      tx.pure.u64(args.impulse),
      tx.pure.u64(args.containmentBurden),
    ],
  })
}

/** Install a Fuel source already holding `load`. Admin-gated. */
export function installFuelWithLoad(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  args: InstallFuelArgs,
  load: TransactionArgument,
): void {
  const request = tx.moveCall({
    target: moveCallTarget(config, 'grid_fuel', 'install_with_fuel'),
    arguments: [
      entity,
      tx.pure.u64(args.componentId),
      tx.pure.option('string', args.name ?? null),
      tx.pure.u64(args.capacity),
      load,
      tx.object.clock(),
    ],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

/** Move a Generator to `to` with its stats and online state. Admin-gated. */
export function migrateGenerator(
  tx: Transaction,
  config: WorldConfig,
  from: TransactionArgument,
  to: TransactionArgument,
  componentId: bigint,
): void {
  migrateWith(
    tx,
    config,
    moveCallTarget(config, 'grid_generator', 'migrate'),
    from,
    to,
    componentId,
  )
}

/** Move a Fuel source to `to` with its share of the fuel. Admin-gated. */
export function migrateFuel(
  tx: Transaction,
  config: WorldConfig,
  from: TransactionArgument,
  to: TransactionArgument,
  componentId: bigint,
): void {
  migrateWith(
    tx,
    config,
    moveCallTarget(config, 'grid_fuel', 'migrate'),
    from,
    to,
    componentId,
  )
}

/**
 * Call a `migrate(from, to, component_id, clock, ctx): (Request, Request)` and
 * close both admin-gated requests.
 */
export function migrateWith(
  tx: Transaction,
  config: WorldConfig,
  target: `${string}::${string}::${string}`,
  from: TransactionArgument,
  to: TransactionArgument,
  componentId: bigint,
): void {
  const [fromRequest, toRequest] = tx.moveCall({
    target,
    arguments: [from, to, tx.pure.u64(componentId), tx.object.clock()],
  })
  verifyAdmin(tx, config, fromRequest)
  completeRequest(tx, config, from, fromRequest)
  verifyAdmin(tx, config, toRequest)
  completeRequest(tx, config, to, toRequest)
}

// === Requirements ===

/**
 * Satisfied by `setPowerGrid`, `setGenerator`, `setPriority` and `setDesiredState`.
 * Each handler also takes the owner's cap.
 */
export function operateGridRequirement(
  tx: Transaction,
  config: WorldConfig,
): TransactionResult {
  return tx.moveCall({ target: grid(config, 'operate_grid_requirement') })
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

/** Assertion: `moduleId` holds a grant of `drawKind` with at least `draw` MW. */
export function onlineRequirement(
  tx: Transaction,
  config: WorldConfig,
  moduleId: bigint,
  draw: bigint,
  drawKind: DrawKind,
): TransactionResult {
  return tx.moveCall({
    target: grid(config, 'online_requirement'),
    arguments: [
      tx.pure.u64(moduleId),
      tx.pure.u64(draw),
      drawKindCall(tx, config, drawKind),
    ],
  })
}

// === Handlers (satisfy the next requirement on `request`) ===

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
  verifyOwner(tx, config, entity, request, ownerCap)
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
  verifyOwner(tx, config, entity, request, ownerCap)
}

/** Bring a Generator online or offline. Owner-gated. */
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
  verifyOwner(tx, config, entity, request, ownerCap)
}

/** Move a connected module into priority group `priority`. Grants ignore it in v1. Owner-gated. */
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
  verifyOwner(tx, config, entity, request, ownerCap)
}

/** Set a connected module's desired state. The grid regrants. Owner-gated. */
export function setDesiredState(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  ownerCap: string | TransactionArgument,
  moduleId: bigint,
  online: boolean,
): void {
  tx.moveCall({
    target: moveCallTarget(config, 'grid_load', 'set_desired_state'),
    arguments: [
      entity,
      request,
      tx.pure.u64(moduleId),
      tx.pure.bool(online),
      tx.object.clock(),
    ],
  })
  verifyOwner(tx, config, entity, request, ownerCap)
}

/** Fuel left on the creation now, with burn since the last settle applied. */
export function projectedFuel(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
): TransactionResult {
  return tx.moveCall({
    target: grid(config, 'projected_fuel'),
    arguments: [entity, tx.object.clock()],
  })
}

/** `(effective capacity, used MW, online module ids)` now. Fuel at zero reads as all zeros. */
export function projectedStatus(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
): TransactionResult {
  return tx.moveCall({
    target: grid(config, 'projected_status'),
    arguments: [entity, tx.object.clock()],
  })
}

/** Live draw for one module now. Zero once the fuel has run out. */
export function moduleDraw(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  moduleId: bigint,
): TransactionResult {
  return tx.moveCall({
    target: grid(config, 'module_draw'),
    arguments: [entity, tx.pure.u64(moduleId), tx.object.clock()],
  })
}

/** Abort unless the module in the next `OnlineRequirement` holds its grant. */
export function assertOnline(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
): void {
  tx.moveCall({
    target: moveCallTarget(config, 'grid_load', 'assert_online'),
    arguments: [entity, request, tx.object.clock()],
  })
}
