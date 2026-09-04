import { bcs } from '@mysten/sui/bcs'
import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import {
  completeRequest,
  deleteEntity,
  deriveObjectId,
  entityNew,
  shareEntity,
  verifyAdmin,
} from '../packages/core.js'
import {
  genericModuleData,
  genericModuleName,
  genericModuleTypeId,
  installGenericModule,
  uninstallGenericModule,
} from '../packages/generic-module.js'
import { expectSuccess, loadLocalnetWorld, signer } from './helpers.js'

const MODULE_ID = 0x70n
const MODULE_ID_2 = 0x71n
const TYPE_ID = 42n
const TYPE_ID_2 = 43n
const DATA = [1, 2, 3, 9]
const DATA_2 = [9, 8, 7]

describe('generic module (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('installs, reads, uninstalls, then deletes the entity', async () => {
    const key = { id: 4700n, tenant: 'generic-t1' }
    const entityId = deriveObjectId(config, key)

    const setupTx = new Transaction()
    const [entity, claimReq] = entityNew(setupTx, config, {
      inGameId: key.id,
      tenant: key.tenant,
    })
    verifyAdmin(setupTx, config, claimReq)
    completeRequest(setupTx, config, entity, claimReq)
    installGenericModule(setupTx, config, entity, {
      moduleId: MODULE_ID,
      typeId: TYPE_ID,
      name: 'thruster',
      data: DATA,
    })
    installGenericModule(setupTx, config, entity, {
      moduleId: MODULE_ID_2,
      typeId: TYPE_ID_2,
      name: 'turret',
      data: DATA_2,
    })
    shareEntity(setupTx, config, entity)
    await expectSuccess(client, setupTx)

    const first = await readGeneric(client, config, entityId, MODULE_ID)
    expect(first.typeId).toBe(TYPE_ID)
    expect(first.data).toEqual(DATA)
    expect(first.name).toBe('thruster')

    const second = await readGeneric(client, config, entityId, MODULE_ID_2)
    expect(second.typeId).toBe(TYPE_ID_2)
    expect(second.data).toEqual(DATA_2)
    expect(second.name).toBe('turret')

    const teardownTx = new Transaction()
    const e = teardownTx.object(entityId)
    uninstallGenericModule(teardownTx, config, e, MODULE_ID)
    uninstallGenericModule(teardownTx, config, e, MODULE_ID_2)
    deleteEntity(teardownTx, config, e)
    const deleted = await expectSuccess(client, teardownTx)

    const deletedIds = deleted.effects.changedObjects
      .filter((o) => o.idOperation === 'Deleted')
      .map((o) => o.objectId)
    expect(deletedIds).toContain(entityId)
  })
})

async function readGeneric(
  client: ReturnType<typeof loadLocalnetWorld>['client'],
  config: ReturnType<typeof loadLocalnetWorld>['config'],
  entityId: string,
  moduleId: bigint,
): Promise<{
  typeId: bigint
  data: number[]
  name: string | null
}> {
  const tx = new Transaction()
  tx.setSender(signer)
  const entity = tx.object(entityId)
  genericModuleTypeId(tx, config, entity, moduleId)
  genericModuleData(tx, config, entity, moduleId)
  genericModuleName(tx, config, entity, moduleId)

  const res = await client.simulateTransaction({
    transaction: tx,
    include: { commandResults: true },
  })
  if (res.FailedTransaction) {
    throw new Error(
      res.FailedTransaction.status.error?.message ?? 'generic view failed',
    )
  }

  const typeId = BigInt(
    bcs.u64().parse(res.commandResults[0].returnValues[0].bcs),
  )
  const data = [
    ...bcs.vector(bcs.u8()).parse(res.commandResults[1].returnValues[0].bcs),
  ]
  const name = bcs
    .option(bcs.string())
    .parse(res.commandResults[2].returnValues[0].bcs)

  return {
    typeId,
    data,
    name,
  }
}
