import { bcs } from '@mysten/sui/bcs'
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

// Power (MW) and fuel bay capacity are plain integers. Fuel amounts, stats and
// rates are fixed point at `POWER_SCALE`: 0.1 units = 1_000n.
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

/** Remove the grid. Aborts while a module, generator, or fuel bay is still connected. */
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

export interface InstallFuelBayArgs {
  componentId: bigint
  name?: string | null
  capacity: bigint
}

/** Install an empty fuel bay, offline. Admin-gated. */
export function installFuelBay(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  args: InstallFuelBayArgs,
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

/** Remove a fuel bay with its exact fuel. Pass the load to `installFuelBayWithLoad` or `burnFuelLoad`. */
export function uninstallFuelBay(
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

/** Destroy a fuel load that is not reinstalled. */
export function burnFuelLoad(
  tx: Transaction,
  config: WorldConfig,
  load: TransactionArgument,
): void {
  tx.moveCall({
    target: moveCallTarget(config, 'grid_fuel', 'burn_fuel_load'),
    arguments: [load],
  })
}

/** Install a fuel bay already holding `load`, offline. Admin-gated. */
export function installFuelBayWithLoad(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  args: InstallFuelBayArgs,
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

/** Move a fuel bay to `to` with its exact fuel. It arrives offline. Admin-gated. */
export function migrateFuelBay(
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
 * Satisfied by `setPowerGrid`, `setGenerator`, `setFuelBay`, `setPriority` and
 * `setDesiredState`. Each handler also takes the owner's cap.
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

/** Fuel to load into one bay. Amount and stats at `POWER_SCALE`. */
export interface DepositFuelArgs {
  fuelBayId: bigint
  fuelType: bigint
  amount: bigint
  impulse: bigint
  containmentBurden: bigint
  volatility: bigint
}

/**
 * Load fuel into one bay; its stats blend by amount. The owner's `ownerCap`
 * authorizes the deposit, and the gas sponsor must be on `AdminACL`.
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
      tx.pure.u64(args.fuelBayId),
      tx.pure.u64(args.fuelType),
      tx.pure.u64(args.amount),
      tx.pure.u64(args.impulse),
      tx.pure.u64(args.containmentBurden),
      tx.pure.u64(args.volatility),
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

/** Bring a fuel bay online or offline. An offline bay keeps its fuel. Owner-gated. */
export function setFuelBay(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  ownerCap: string | TransactionArgument,
  fuelBayId: bigint,
  online: boolean,
): void {
  tx.moveCall({
    target: moveCallTarget(config, 'grid_fuel', 'set_fuel_bay'),
    arguments: [
      entity,
      request,
      tx.pure.u64(fuelBayId),
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

/** Fuel in online bays now, with burn since the last settle applied. */
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

/**
 * Every installed bay now, as a `VecMap<u64, FuelBayState>`; parse it with
 * `parseProjectedBays`.
 */
export function projectedBays(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
): TransactionResult {
  return tx.moveCall({
    target: grid(config, 'projected_bays'),
    arguments: [entity, tx.object.clock()],
  })
}

const FuelBcs = bcs.struct('Fuel', {
  quantity: bcs.u64(),
  impulse: bcs.u64(),
  containment_burden: bcs.u64(),
  volatility: bcs.u64(),
})

const FuelBayStateBcs = bcs.struct('FuelBayState', {
  capacity: bcs.u64(),
  online: bcs.bool(),
  fuel: FuelBcs,
})

const BaysBcs = bcs.struct('VecMap', {
  contents: bcs.vector(
    bcs.struct('Entry', { key: bcs.u64(), value: FuelBayStateBcs }),
  ),
})

/** A fuel bay as `projectedBays` returns it. Fuel values at `POWER_SCALE`. */
export interface ProjectedBay {
  fuelBayId: bigint
  capacity: bigint
  online: boolean
  quantity: bigint
  impulse: bigint
  containmentBurden: bigint
  volatility: bigint
}

/** Decode the BCS return value of `projectedBays`. */
export function parseProjectedBays(bytes: Uint8Array): ProjectedBay[] {
  return BaysBcs.parse(bytes).contents.map(({ key, value }) => ({
    fuelBayId: BigInt(key),
    capacity: BigInt(value.capacity),
    online: value.online,
    quantity: BigInt(value.fuel.quantity),
    impulse: BigInt(value.fuel.impulse),
    containmentBurden: BigInt(value.fuel.containment_burden),
    volatility: BigInt(value.fuel.volatility),
  }))
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
