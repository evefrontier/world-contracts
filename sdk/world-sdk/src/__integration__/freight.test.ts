import { fileURLToPath } from 'node:url'
import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import { createWorldClient } from '../client.js'
import { loadWorldConfig } from '../config/load.js'
import {
  callerRequirement,
  completeRequest,
  deriveObjectId,
  enableAction,
  entityNew,
  interact,
  mintAccess,
  shareEntity,
  verifyAdmin,
  verifyCaller,
  verifyProximity,
} from '../packages/core.js'
import {
  dropoff,
  dropoffRequirement,
  pickup,
  pickupRequirement,
} from '../packages/freight.js'
import {
  bridgeInRequirement,
  createStorageUnit,
  deposit,
  depositRequirement,
  gameItemToChain,
  withdraw,
  withdrawRequirement,
} from '../packages/inventory.js'
import {
  capObjectId,
  expectSuccess,
  readBalance,
  requirePackage,
  signer,
} from './helpers.js'

// Two-transaction freight haul: withdraw+receipt at source, dropoff+deposit at
// destination. Needs a funded localnet admin key and a manifest that includes
// the freight package (redeploy after adding freight to deploy-world.sh).
const MANIFEST = fileURLToPath(
  new URL('../../../../deployments/localnet/world.json', import.meta.url),
)

const UNIT = 'SU-01'
const FUEL = 88834n
const VOL = 2n
const QTY = 10n

function createdObjectId(
  result: Awaited<ReturnType<typeof expectSuccess>>,
  objectTypeSuffix: string,
): string {
  const created = result.objectChanges?.find(
    (c) =>
      c.type === 'created' &&
      'objectType' in c &&
      typeof c.objectType === 'string' &&
      c.objectType.endsWith(objectTypeSuffix),
  )
  const id = (created as { objectId?: string } | undefined)?.objectId
  if (!id) {
    throw new Error(`created object ending with ${objectTypeSuffix} not found`)
  }
  return id
}

describe('freight pickup/dropoff (localnet)', () => {
  const config = loadWorldConfig(MANIFEST)
  const client = createWorldClient({ config })

  it('delivers an exact withdrawn Item across two storage units', async () => {
    requirePackage(config, 'freight')
    const coreId = requirePackage(config, 'core')

    const sourceKey = { id: 6100n, tenant: 'freight-t1' }
    const destKey = { id: 6101n, tenant: 'freight-t1' }
    const carrierKey = { id: 6102n, tenant: 'freight-t1' }
    const sourceId = deriveObjectId(config, sourceKey)
    const destId = deriveObjectId(config, destKey)
    // Carrier identity is a bare entity with a soulbound AccessCap (no character
    // module required for caller authorization).
    const carrierEntityId = deriveObjectId(config, carrierKey)

    // tx1: create source + dest storage units and a carrier entity.
    const createTx = new Transaction()
    createStorageUnit(createTx, config, {
      inGameId: sourceKey.id,
      tenant: sourceKey.tenant,
      name: UNIT,
      mainCapacity: 1000n,
      ephemeralCapacity: 100n,
    })
    createStorageUnit(createTx, config, {
      inGameId: destKey.id,
      tenant: destKey.tenant,
      name: UNIT,
      mainCapacity: 1000n,
      ephemeralCapacity: 100n,
    })
    {
      const [carrier, claimReq] = entityNew(createTx, config, {
        inGameId: carrierKey.id,
        tenant: carrierKey.tenant,
      })
      verifyAdmin(createTx, config, claimReq)
      completeRequest(createTx, config, carrier, claimReq)
      shareEntity(createTx, config, carrier)
    }
    await expectSuccess(client, createTx)

    // tx2–4: mint owner/carrier caps separately so object ids are unambiguous.
    const sourceMint = new Transaction()
    mintAccess(sourceMint, config, {
      entity: sourceId,
      owner: signer,
      transferable: true,
    })
    const sourceCapId = capObjectId(
      await expectSuccess(client, sourceMint, { showObjectChanges: true }),
      coreId,
    )

    const destMint = new Transaction()
    mintAccess(destMint, config, {
      entity: destId,
      owner: signer,
      transferable: true,
    })
    const destCapId = capObjectId(
      await expectSuccess(client, destMint, { showObjectChanges: true }),
      coreId,
    )

    const carrierMint = new Transaction()
    mintAccess(carrierMint, config, {
      entity: carrierEntityId,
      owner: signer,
      transferable: false,
    })
    const carrierCapId = capObjectId(
      await expectSuccess(client, carrierMint, { showObjectChanges: true }),
      coreId,
    )

    // tx5: configure freight actions + stock the source.
    const enableTx = new Transaction()
    const source = enableTx.object(sourceId)
    const dest = enableTx.object(destId)
    const sourceCap = enableTx.object(sourceCapId)
    const destCap = enableTx.object(destCapId)

    enableAction(
      enableTx,
      config,
      source,
      'bridge_in',
      [
        callerRequirement(enableTx, config),
        bridgeInRequirement(enableTx, config, UNIT, { ephemeral: false }),
      ],
      sourceCap,
    )
    enableAction(
      enableTx,
      config,
      source,
      'freight_pickup',
      [
        callerRequirement(enableTx, config),
        withdrawRequirement(enableTx, config, UNIT, {
          ephemeral: false,
          typeId: FUEL,
        }),
        pickupRequirement(enableTx, config, destId),
      ],
      sourceCap,
    )
    enableAction(
      enableTx,
      config,
      dest,
      'freight_dropoff',
      [
        callerRequirement(enableTx, config),
        dropoffRequirement(enableTx, config),
        depositRequirement(enableTx, config, UNIT, {
          ephemeral: false,
          typeId: FUEL,
        }),
      ],
      destCap,
    )

    const stockReq = interact(enableTx, config, source, 'bridge_in')
    verifyProximity(enableTx, config, stockReq)
    verifyCaller(enableTx, config, stockReq, sourceCap)
    gameItemToChain(enableTx, config, source, stockReq, {
      typeId: FUEL,
      quantity: 100n,
      volume: VOL,
    })
    completeRequest(enableTx, config, source, stockReq)
    await expectSuccess(client, enableTx)

    // tx6: carrier pickup — withdraw + issue receipt.
    const pickupTx = new Transaction()
    const src = pickupTx.object(sourceId)
    const carrierCap = pickupTx.object(carrierCapId)
    const pickReq = interact(pickupTx, config, src, 'freight_pickup')
    verifyProximity(pickupTx, config, pickReq)
    verifyCaller(pickupTx, config, pickReq, carrierCap)
    const item = withdraw(pickupTx, config, src, pickReq, {
      typeId: FUEL,
      quantity: QTY,
    })
    const receipt = pickup(pickupTx, config, src, pickReq, item)
    completeRequest(pickupTx, config, src, pickReq)
    pickupTx.transferObjects([item, receipt], signer)

    const picked = await expectSuccess(client, pickupTx, {
      showObjectChanges: true,
      showEvents: true,
    })
    const itemId = createdObjectId(picked, '::item::Item')
    const receiptId = createdObjectId(picked, '::freight::FreightReceipt')
    const pickupEvents = picked.events?.filter((e) =>
      e.type.endsWith('::freight::FreightPickedUp'),
    )
    expect(pickupEvents?.length).toBe(1)

    // tx7: carrier dropoff — consume receipt + deposit exact Item.
    const dropTx = new Transaction()
    const dst = dropTx.object(destId)
    const cCap = dropTx.object(carrierCapId)
    const dropReq = interact(dropTx, config, dst, 'freight_dropoff')
    verifyProximity(dropTx, config, dropReq)
    verifyCaller(dropTx, config, dropReq, cCap)
    dropoff(
      dropTx,
      config,
      dst,
      dropReq,
      dropTx.object(itemId),
      dropTx.object(receiptId),
    )
    deposit(dropTx, config, dst, dropReq, dropTx.object(itemId))
    completeRequest(dropTx, config, dst, dropReq)

    const delivered = await expectSuccess(client, dropTx, { showEvents: true })
    const deliveredEvents = delivered.events?.filter((e) =>
      e.type.endsWith('::freight::FreightDelivered'),
    )
    expect(deliveredEvents?.length).toBe(1)

    const sourceBal = await readBalance(client, config, {
      entity: sourceId,
      name: UNIT,
      authorizedId: sourceId,
      typeId: FUEL,
    })
    const destBal = await readBalance(client, config, {
      entity: destId,
      name: UNIT,
      authorizedId: destId,
      typeId: FUEL,
    })
    expect(sourceBal).toBe(90n)
    expect(destBal).toBe(QTY)
  })
})
