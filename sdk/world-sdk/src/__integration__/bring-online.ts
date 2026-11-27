import type { Signer } from '@mysten/sui/cryptography'
import { Transaction, type TransactionArgument } from '@mysten/sui/transactions'
import type { WorldClient } from '../client.js'
import type { WorldConfig } from '../config/types.js'
import {
  addSponsors,
  completeRequest,
  enableAdminAction,
  interact,
} from '../packages/core.js'
import {
  depositFuel,
  depositFuelRequirement,
  installFuelBay,
  installGenerator,
  operateGridRequirement,
  POWER_SCALE,
  setDesiredState,
  setFuelBay,
  setGenerator,
  setPowerGrid,
} from '../packages/power.js'
import { MASS_UNIT } from '../packages/variant.js'
import {
  expectSponsored,
  expectSuccess,
  fuelVariant,
  keypair,
  seatShell,
  signer,
} from './helpers.js'

const GENERATOR_ID = 0x71n
/** The fuel bay `installInventoryPower` installs. */
export const FUEL_BAY_ID = 0x72n

/** Stats of the fuel `installInventoryPower` registers, less the tenant. */
export const INVENTORY_FUEL = {
  fuelType: 7n,
  impulse: 90n * POWER_SCALE,
  containmentBurden: 14n * POWER_SCALE,
  volatility: 5n * POWER_SCALE,
}

/**
 * Install a generator and fuel bay and expose the owner steps that turn a
 * module on. Returns the fuel variant (in the entity's `tenant`) to pass to
 * `powerInventoryOn`, which comes next with the entity owner's cap.
 */
export async function installInventoryPower(
  client: WorldClient,
  config: WorldConfig,
  entityId: string,
  tenant: string,
): Promise<string> {
  const installTx = new Transaction()
  const entity = installTx.object(entityId)
  installGenerator(installTx, config, entity, {
    componentId: GENERATOR_ID,
    maxOutputMw: 10n * POWER_SCALE,
    fuelType: INVENTORY_FUEL.fuelType,
    impulseLimit: 100n * POWER_SCALE,
    volatilityLimit: 1n,
  })
  installFuelBay(installTx, config, entity, {
    componentId: FUEL_BAY_ID,
    capacity: 1_000n * POWER_SCALE,
  })
  seatShell(installTx, config, entity)
  await expectSuccess(client, installTx)

  const enableTx = new Transaction()
  addSponsors(enableTx, config, [signer])
  const enableEntity = enableTx.object(entityId)
  enableAdminAction(enableTx, config, enableEntity, 'deposit_fuel', [
    depositFuelRequirement(enableTx, config),
  ])
  enableAdminAction(enableTx, config, enableEntity, 'set_power_grid', [
    operateGridRequirement(enableTx, config),
  ])
  enableAdminAction(enableTx, config, enableEntity, 'set_generator', [
    operateGridRequirement(enableTx, config),
  ])
  enableAdminAction(enableTx, config, enableEntity, 'set_fuel_bay', [
    operateGridRequirement(enableTx, config),
  ])
  enableAdminAction(enableTx, config, enableEntity, 'set_desired_state', [
    operateGridRequirement(enableTx, config),
  ])
  await expectSuccess(client, enableTx)

  return fuelVariant(client, config, { tenant, ...INVENTORY_FUEL })
}

/** Fuel the bay with `fuelVariantId`, bring it online, switch the grid on, and grant `moduleId`. The owner cap authorizes each step. */
export function powerInventoryOn(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  ownerCap: TransactionArgument,
  moduleId: bigint,
  fuelVariantId: string,
): void {
  const fuelRequest = interact(tx, config, entity, 'deposit_fuel')
  depositFuel(tx, config, entity, fuelRequest, ownerCap, {
    fuelBayId: FUEL_BAY_ID,
    variant: fuelVariantId,
    amount: 100n * MASS_UNIT,
  })
  completeRequest(tx, config, entity, fuelRequest)

  const bayRequest = interact(tx, config, entity, 'set_fuel_bay')
  setFuelBay(tx, config, entity, bayRequest, ownerCap, FUEL_BAY_ID, true)
  completeRequest(tx, config, entity, bayRequest)

  const gridRequest = interact(tx, config, entity, 'set_power_grid')
  setPowerGrid(tx, config, entity, gridRequest, ownerCap, true)
  completeRequest(tx, config, entity, gridRequest)

  const generatorRequest = interact(tx, config, entity, 'set_generator')
  setGenerator(
    tx,
    config,
    entity,
    generatorRequest,
    ownerCap,
    GENERATOR_ID,
    true,
  )
  completeRequest(tx, config, entity, generatorRequest)

  const desiredRequest = interact(tx, config, entity, 'set_desired_state')
  setDesiredState(tx, config, entity, desiredRequest, ownerCap, moduleId, true)
  completeRequest(tx, config, entity, desiredRequest)
}

/** Install power sources, then grant `moduleId`. `tenant` is the entity's. `owner` signs the grant; admin pays gas. */
export async function bringInventoryOnline(
  client: WorldClient,
  config: WorldConfig,
  entityId: string,
  tenant: string,
  capId: string,
  moduleId: bigint,
  owner: Signer = keypair,
): Promise<void> {
  const fuel = await installInventoryPower(client, config, entityId, tenant)
  const onlineTx = new Transaction()
  if (owner.toSuiAddress() === signer) addSponsors(onlineTx, config, [signer])
  const entity = onlineTx.object(entityId)
  powerInventoryOn(
    onlineTx,
    config,
    entity,
    onlineTx.object(capId),
    moduleId,
    fuel,
  )
  if (owner.toSuiAddress() === signer) {
    await expectSuccess(client, onlineTx)
    return
  }
  await expectSponsored(client, onlineTx, owner)
}
