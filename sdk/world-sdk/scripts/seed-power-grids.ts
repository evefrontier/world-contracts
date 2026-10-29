import { Transaction } from '@mysten/sui/transactions'
import { signAndExecute } from '../src/client.js'
import { componentIdFromName } from '../src/packages/component-id.js'
import { deriveObjectId, enableAdminAction } from '../src/packages/core.js'
import {
  depositFuelRequirement,
  installFuelBay,
  installGenerator,
  operateGridRequirement,
  POWER_SCALE,
} from '../src/packages/power.js'
import { loadScriptContext } from './context.js'
import { loadSeedFiles } from './seed-files.js'

// Give every seeded storage unit a generator and a fuel bay. The inventory
// already connected to the grid when the storage unit was created.
const GENERATOR_ID = componentIdFromName('generator')
const FUEL_ID = componentIdFromName('fuel')
const OUTPUT = 15n
const CONTAINMENT_REDUCTION = 10n * POWER_SCALE
const BASE_FUEL_RATE = POWER_SCALE
const FUEL_CAPACITY = 1000n

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
  installGenerator(tx, config, entity, {
    componentId: GENERATOR_ID,
    maxOutputMw: OUTPUT,
    containmentReduction: CONTAINMENT_REDUCTION,
    baseFuelRate: BASE_FUEL_RATE,
  })
  installFuelBay(tx, config, entity, {
    componentId: FUEL_ID,
    capacity: FUEL_CAPACITY,
  })
  enableAdminAction(tx, config, entity, 'set_power_grid', [
    operateGridRequirement(tx, config),
  ])
  enableAdminAction(tx, config, entity, 'set_generator', [
    operateGridRequirement(tx, config),
  ])
  enableAdminAction(tx, config, entity, 'set_fuel_bay', [
    operateGridRequirement(tx, config),
  ])
  enableAdminAction(tx, config, entity, 'set_priority', [
    operateGridRequirement(tx, config),
  ])
  enableAdminAction(tx, config, entity, 'set_desired_state', [
    operateGridRequirement(tx, config),
  ])
  enableAdminAction(tx, config, entity, 'deposit_fuel', [
    depositFuelRequirement(tx, config),
  ])

  const result = await signAndExecute(client, {
    signer: keypair,
    transaction: tx,
  })
  await client.waitForTransaction({ digest: result.digest })
  console.log(`${alias}: power grid on ${entityId} (digest ${result.digest})`)
}
