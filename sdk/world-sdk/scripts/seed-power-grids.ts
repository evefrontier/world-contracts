import { Transaction } from '@mysten/sui/transactions'
import { signAndExecute } from '../src/client.js'
import { componentIdFromName } from '../src/packages/component-id.js'
import {
  completeRequest,
  deriveObjectId,
  enableAdminAction,
  interact,
  ownerRequirement,
} from '../src/packages/core.js'
import {
  connectModule,
  depositFuelRequirement,
  installFuel,
  installGenerator,
  installPowerGrid,
  manageFuelRequirement,
  manageGeneratorRequirement,
  manageModuleRequirement,
  operateGridRequirement,
  POWER_SCALE,
  registerFuelSource,
  registerGenerator,
} from '../src/packages/power.js'
import { loadScriptContext } from './context.js'
import { loadSeedFiles } from './seed-files.js'

// Give every seeded storage unit a power grid: one 15 MW generator, one fuel
// bay, its inventory connected. The owner deposits fuel and powers it on.
const GENERATOR_ID = componentIdFromName('generator')
const FUEL_ID = componentIdFromName('fuel')
const OUTPUT = 15n * POWER_SCALE
const CONTAINMENT_REDUCTION = 10n * POWER_SCALE
const BASE_FUEL_RATE = POWER_SCALE
const FUEL_CAPACITY = 1000n * POWER_SCALE

const { repoRoot, config, client, keypair } = loadScriptContext()
const { resources } = loadSeedFiles(repoRoot)

const entries = Object.entries(resources.storageUnit ?? {})
if (entries.length === 0) {
  console.log('no storageUnit entries in test-resources.json; nothing to do.')
  process.exit(0)
}

for (const [alias, unit] of entries) {
  if (unit.itemId === undefined) {
    throw new Error(`test-resources.json storageUnit.${alias} needs itemId`)
  }
  const inventoryId = BigInt(unit.itemId)
  const entityId = deriveObjectId(config, {
    id: inventoryId,
    tenant: resources.tenant,
  })

  const tx = new Transaction()
  const entity = tx.object(entityId)
  installPowerGrid(tx, config, entity)
  installGenerator(tx, config, entity, GENERATOR_ID)
  installFuel(tx, config, entity, FUEL_ID)
  enableAdminAction(tx, config, entity, 'register_generator', [
    manageGeneratorRequirement(tx, config),
  ])
  enableAdminAction(tx, config, entity, 'connect_module', [
    manageModuleRequirement(tx, config),
  ])
  enableAdminAction(tx, config, entity, 'register_fuel_source', [
    manageFuelRequirement(tx, config),
  ])
  enableAdminAction(tx, config, entity, 'set_power_grid', [
    ownerRequirement(tx, config),
    operateGridRequirement(tx, config),
  ])
  enableAdminAction(tx, config, entity, 'set_generator', [
    ownerRequirement(tx, config),
    operateGridRequirement(tx, config),
  ])
  enableAdminAction(tx, config, entity, 'reserve', [
    ownerRequirement(tx, config),
    operateGridRequirement(tx, config),
  ])
  enableAdminAction(tx, config, entity, 'deposit_fuel', [
    depositFuelRequirement(tx, config),
  ])

  const registerGeneratorRequest = interact(
    tx,
    config,
    entity,
    'register_generator',
  )
  registerGenerator(tx, config, entity, registerGeneratorRequest, {
    generatorId: GENERATOR_ID,
    maxOutputMw: OUTPUT,
    containmentReduction: CONTAINMENT_REDUCTION,
    baseFuelRate: BASE_FUEL_RATE,
  })
  completeRequest(tx, config, entity, registerGeneratorRequest)
  const registerFuelSourceRequest = interact(
    tx,
    config,
    entity,
    'register_fuel_source',
  )
  registerFuelSource(
    tx,
    config,
    entity,
    registerFuelSourceRequest,
    FUEL_ID,
    FUEL_CAPACITY,
  )
  completeRequest(tx, config, entity, registerFuelSourceRequest)
  const connectModuleRequest = interact(tx, config, entity, 'connect_module')
  connectModule(tx, config, entity, connectModuleRequest, inventoryId, 0n)
  completeRequest(tx, config, entity, connectModuleRequest)

  const result = await signAndExecute(client, {
    signer: keypair,
    transaction: tx,
  })
  await client.waitForTransaction({ digest: result.digest })
  console.log(`${alias}: power grid on ${entityId} (digest ${result.digest})`)
}
