import { bcs } from '@mysten/sui/bcs'
import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import type { WorldConfig } from '../config/types.js'
import {
  addSponsors,
  completeRequest,
  deriveObjectId,
  enableAdminAction,
  entityNew,
  interact,
  shareEntity,
  verifyAdmin,
} from '../packages/core.js'
import {
  genericModuleData,
  installGenericModule,
} from '../packages/generic-module.js'
import { installInventory } from '../packages/inventory.js'
import {
  installLayout,
  type LayoutSection,
  sectionIds,
  sectionModules,
} from '../packages/layout.js'
import {
  depositFuel,
  depositFuelRequirement,
  installFuelBay,
  installGenerator,
  installPowerGrid,
  POWER_SCALE,
  parseProjectedBays,
  projectedBays,
} from '../packages/power.js'
import {
  detachSection,
  mergeCreation,
  type SectionModule,
  type SectionSpec,
} from '../packages/sections.js'
import {
  expectAbort,
  expectSuccess,
  loadLocalnetWorld,
  mintAccessCap,
  signer,
} from './helpers.js'

const TENANT = 'sections-t1'
const DATA = [1, 2, 3, 9]
const IMPULSE = 90n * POWER_SCALE
const BURDEN = 14n * POWER_SCALE
const VOLATILITY = 5n * POWER_SCALE

type World = ReturnType<typeof loadLocalnetWorld>

describe('sections (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('detaches a section into a new creation by reinstalling its modules', async () => {
    const sourceKey = { inGameId: 4800n, tenant: TENANT }
    const targetKey = { inGameId: 4801n, tenant: TENANT }
    const sourceId = deriveObjectId(config, {
      id: sourceKey.inGameId,
      tenant: TENANT,
    })
    const targetId = deriveObjectId(config, {
      id: targetKey.inGameId,
      tenant: TENANT,
    })
    const kept: SectionSpec = {
      sectionId: 1n,
      modules: [
        generic(0x80n),
        { kind: 'fuelBay', componentId: 0x81n, capacity: 1_000_000n },
      ],
    }
    const leaving: SectionSpec = {
      sectionId: 2n,
      modules: [
        generic(0x82n),
        generator(0x83n),
        { kind: 'fuelBay', componentId: 0x84n, capacity: 3_000_000n },
      ],
    }

    // Each bay holds its own fuel: 10 units stay, 30 leave.
    const setupTx = new Transaction()
    const source = deploy(setupTx, config, sourceKey, [kept, leaving])
    shareEntity(setupTx, config, source)
    await expectSuccess(client, setupTx)
    await seedFuel(client, config, sourceId, [
      [0x81n, 10n],
      [0x84n, 30n],
    ])

    const detachTx = new Transaction()
    detachSection(
      detachTx,
      config,
      detachTx.object(sourceId),
      targetKey,
      leaving,
      'reinstall',
    )
    await expectSuccess(client, detachTx)

    expect(await readSections(client, config, sourceId)).toEqual([1n])
    expect(await readSections(client, config, targetId)).toEqual([2n])
    expect(await readSectionModules(client, config, targetId, 2n)).toEqual([
      0x82n,
      0x83n,
      0x84n,
    ])
    // Each bay kept exactly its own fuel.
    expect(await readBayFuel(client, config, sourceId, 0x81n)).toBe(100_000n)
    expect(await readBayFuel(client, config, targetId, 0x84n)).toBe(300_000n)
    expect(await readGenericData(client, config, targetId, 0x82n)).toEqual(DATA)

    // The source's last section cannot leave.
    const lastTx = new Transaction()
    detachSection(
      lastTx,
      config,
      lastTx.object(sourceId),
      { inGameId: 4802n, tenant: TENANT },
      kept,
      'reinstall',
    )
    await expectAbort(client, lastTx, signer, /ELastSection/)
  })

  it('merges a creation into another by migrating its modules', async () => {
    const survivorKey = { inGameId: 4810n, tenant: TENANT }
    const absorbedKey = { inGameId: 4811n, tenant: TENANT }
    const survivorId = deriveObjectId(config, {
      id: survivorKey.inGameId,
      tenant: TENANT,
    })
    const absorbedId = deriveObjectId(config, {
      id: absorbedKey.inGameId,
      tenant: TENANT,
    })
    const survivorSection: SectionSpec = {
      sectionId: 1n,
      modules: [
        generic(0x90n),
        { kind: 'inventory', componentId: 0x91n, typeId: 1n, capacity: 1_000n },
      ],
    }
    const absorbedSection: SectionSpec = {
      sectionId: 2n,
      modules: [
        generic(0x92n),
        generator(0x93n),
        { kind: 'fuelBay', componentId: 0x94n, capacity: 1_000_000n },
      ],
    }

    const setupTx = new Transaction()
    shareEntity(
      setupTx,
      config,
      deploy(setupTx, config, survivorKey, [survivorSection]),
    )
    shareEntity(
      setupTx,
      config,
      deploy(setupTx, config, absorbedKey, [absorbedSection]),
    )
    await expectSuccess(client, setupTx)
    await seedFuel(client, config, absorbedId, [[0x94n, 25n]])

    const mergeTx = new Transaction()
    mergeCreation(
      mergeTx,
      config,
      mergeTx.object(survivorId),
      mergeTx.object(absorbedId),
      [absorbedSection],
      'migrate',
    )
    const merged = await expectSuccess(client, mergeTx)

    expect(await readSections(client, config, survivorId)).toEqual([1n, 2n])
    expect(await readSectionModules(client, config, survivorId, 2n)).toEqual([
      0x92n,
      0x93n,
      0x94n,
    ])
    expect(await readBayFuel(client, config, survivorId, 0x94n)).toBe(250_000n)
    expect(await readGenericData(client, config, survivorId, 0x92n)).toEqual(
      DATA,
    )
    const deleted = merged.effects.changedObjects
      .filter((o) => o.idOperation === 'Deleted')
      .map((o) => o.objectId)
    expect(deleted).toContain(absorbedId)
  })
})

function generic(componentId: bigint): SectionModule {
  return { kind: 'generic', componentId, typeId: 42n, data: DATA }
}

function generator(componentId: bigint): SectionModule {
  return {
    kind: 'generator',
    componentId,
    maxOutputMw: 15n,
    containmentReduction: 10n,
    baseFuelRate: 1n,
  }
}

/** Build an unshared creation with a grid, its modules, and a Layout. */
function deploy(
  tx: Transaction,
  config: WorldConfig,
  key: { inGameId: bigint; tenant: string },
  sections: SectionSpec[],
) {
  const [entity, request] = entityNew(tx, config, key)
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
  installPowerGrid(tx, config, entity)
  for (const module of sections.flatMap((s) => s.modules)) {
    switch (module.kind) {
      case 'generic':
        installGenericModule(tx, config, entity, module)
        break
      case 'inventory':
        installInventory(tx, config, entity, module)
        break
      case 'generator':
        installGenerator(tx, config, entity, module)
        break
      case 'fuelBay':
        installFuelBay(tx, config, entity, module)
        break
    }
  }
  const layout: LayoutSection[] = sections.map((s) => ({
    sectionId: s.sectionId,
    moduleIds: s.modules.map((m) => m.componentId),
  }))
  installLayout(tx, config, entity, layout)
  return entity
}

/** Deposit each `[fuelBayId, amount]` into that bay of a shared creation. */
async function seedFuel(
  client: World['client'],
  config: WorldConfig,
  entityId: string,
  deposits: [bigint, bigint][],
) {
  const capId = await mintAccessCap(client, config, {
    entity: entityId,
    owner: signer,
    transferable: false,
  })
  const tx = new Transaction()
  addSponsors(tx, config, [signer])
  const entity = tx.object(entityId)
  enableAdminAction(tx, config, entity, 'deposit_fuel', [
    depositFuelRequirement(tx, config),
  ])
  for (const [fuelBayId, amount] of deposits) {
    const request = interact(tx, config, entity, 'deposit_fuel')
    depositFuel(tx, config, entity, request, tx.object(capId), {
      fuelBayId,
      fuelType: 1n,
      amount,
      impulse: IMPULSE,
      containmentBurden: BURDEN,
      volatility: VOLATILITY,
    })
    completeRequest(tx, config, entity, request)
  }
  await expectSuccess(client, tx)
}

/** Simulate one view call on `entityId` and return its first return value's bytes. */
async function view(
  client: World['client'],
  build: (tx: Transaction) => void,
): Promise<Uint8Array> {
  const tx = new Transaction()
  tx.setSender(signer)
  build(tx)
  const res = await client.simulateTransaction({
    transaction: tx,
    include: { commandResults: true },
  })
  if (res.FailedTransaction) {
    throw new Error(
      res.FailedTransaction.status.error?.message ?? 'view failed',
    )
  }
  const value = res.commandResults.at(-1)?.returnValues[0]
  if (!value) throw new Error('view returned no value')
  return value.bcs
}

async function readSections(
  client: World['client'],
  config: WorldConfig,
  entityId: string,
): Promise<bigint[]> {
  const bytes = await view(client, (tx) =>
    sectionIds(tx, config, tx.object(entityId)),
  )
  return bcs.vector(bcs.u64()).parse(bytes).map(BigInt)
}

async function readSectionModules(
  client: World['client'],
  config: WorldConfig,
  entityId: string,
  sectionId: bigint,
): Promise<bigint[]> {
  const bytes = await view(client, (tx) =>
    sectionModules(tx, config, tx.object(entityId), sectionId),
  )
  return bcs.vector(bcs.u64()).parse(bytes).map(BigInt)
}

async function readBayFuel(
  client: World['client'],
  config: WorldConfig,
  entityId: string,
  fuelBayId: bigint,
): Promise<bigint> {
  const bytes = await view(client, (tx) =>
    projectedBays(tx, config, tx.object(entityId)),
  )
  const bay = parseProjectedBays(bytes).find((b) => b.fuelBayId === fuelBayId)
  if (!bay) throw new Error(`fuel bay ${fuelBayId} not installed`)
  return bay.quantity
}

async function readGenericData(
  client: World['client'],
  config: WorldConfig,
  entityId: string,
  componentId: bigint,
): Promise<number[]> {
  const bytes = await view(client, (tx) =>
    genericModuleData(tx, config, tx.object(entityId), componentId),
  )
  return [...bcs.vector(bcs.u8()).parse(bytes)]
}
