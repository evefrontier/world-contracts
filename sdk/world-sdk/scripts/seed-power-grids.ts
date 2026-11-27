import { Transaction } from '@mysten/sui/transactions'
import { signAndExecute } from '../src/client.js'
import { componentIdFromName } from '../src/packages/component-id.js'
import { deriveObjectId, enableAdminAction } from '../src/packages/core.js'
import { installLayout, setShell } from '../src/packages/layout.js'
import {
  depositFuelRequirement,
  installFuelBay,
  installGenerator,
  operateGridRequirement,
  POWER_SCALE,
} from '../src/packages/power.js'
import { loadScriptContext } from './context.js'
import { loadSeedFiles } from './seed-files.js'

// Give every seeded storage unit a generator, a fuel bay, and a Shell (power
// needs one to switch anything). The inventory already connected to the grid
// when the storage unit was created. The grid stands in as the Command Module.
const GENERATOR_ID = componentIdFromName('generator')
const FUEL_ID = componentIdFromName('fuel')
const GRID_ID = componentIdFromName('power_grid')
const SHELL_ID = '0x5e11'
const OUTPUT = 15n * POWER_SCALE
// Fuel type 7, impulse limit 100 and volatility limit 1e-9 (at POWER_SCALE):
// any type-7 fuel with volatility gives full output. Bay capacity 1,000 m³.
const FUEL_TYPE = 7n
const IMPULSE_LIMIT = 100n * POWER_SCALE
const VOLATILITY_LIMIT = 1n
const FUEL_CAPACITY = 1_000n * POWER_SCALE

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
    fuelType: FUEL_TYPE,
    maxOutputMw: OUTPUT,
    impulseLimit: IMPULSE_LIMIT,
    volatilityLimit: VOLATILITY_LIMIT,
  })
  installFuelBay(tx, config, entity, {
    componentId: FUEL_ID,
    capacity: FUEL_CAPACITY,
  })
  installLayout(tx, config, entity, [{ sectionId: 1n, moduleIds: [GRID_ID] }])
  setShell(tx, config, entity, SHELL_ID, GRID_ID)
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
