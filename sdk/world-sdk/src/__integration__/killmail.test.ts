import { Transaction } from '@mysten/sui/transactions'
import { beforeAll, describe, expect, it } from 'vitest'
import { createCharacter } from '../packages/character.js'
import { addSponsors } from '../packages/core.js'
import {
  createKillmail,
  type KillmailArgs,
  killmailObjectId,
  LOSS_TYPE_SHIP,
  LOSS_TYPE_STRUCTURE,
} from '../packages/killmail.js'
import {
  expectAbort,
  expectSponsored,
  expectSuccess,
  genesisAccount,
  loadLocalnetWorld,
  requirePackage,
  signer,
} from './helpers.js'

// Integration: creates killmails against a running localnet, and reads them back.
const TENANT = 'killmail-t1'
const REPORTER_ID = 5n

describe('createKillmail (localnet)', () => {
  const { config, client } = loadLocalnetWorld()
  const player = genesisAccount('PLAYER_A')

  const args = (inGameId: bigint): KillmailArgs => ({
    inGameId,
    tenant: TENANT,
    reporterId: REPORTER_ID,
    killerId: 1n,
    victimId: 2n,
    lossType: LOSS_TYPE_SHIP,
    solarSystemId: 4n,
    killTime: new Date(),
  })

  /** The killmail at `inGameId` is shared at its derived id, as a `record::Killmail`. */
  async function expectSharedKillmail(inGameId: bigint): Promise<void> {
    const id = killmailObjectId(config, {
      tenant: TENANT,
      killmailId: inGameId,
    })
    const { object } = await client.getObject({ objectId: id })
    const killmailPkg = requirePackage(config, 'killmail')
    expect(object.type).toBe(`${killmailPkg}::record::Killmail`)
    expect(object.owner.$kind).toBe('Shared')
  }

  beforeAll(async () => {
    // The reporter must already exist on-chain as a character (identity installed),
    // and the admin must be a sponsor to create or pay for killmails.
    const tx = new Transaction()
    addSponsors(tx, config, [signer])
    createCharacter(tx, config, {
      inGameId: REPORTER_ID,
      tenant: TENANT,
      tribeId: 1,
      owner: player.toSuiAddress(),
    })
    await expectSuccess(client, tx)
  })

  it('a sponsor creates a killmail, shared at the derived id', async () => {
    const tx = new Transaction()
    createKillmail(tx, config, args(7n))
    const result = await expectSuccess(client, tx)

    const created = (result.events ?? []).filter((event) =>
      event.eventType.endsWith('::record::KillmailCreated'),
    )
    expect(created).toHaveLength(1)
    await expectSharedKillmail(7n)
  })

  it('a sponsored transaction authorizes the gas sponsor, not the sender', async () => {
    // PLAYER_A sends (not a sponsor); the admin pays gas (a sponsor).
    const tx = new Transaction()
    createKillmail(tx, config, {
      ...args(8n),
      lossType: LOSS_TYPE_STRUCTURE,
    })
    await expectSponsored(client, tx, player)
    await expectSharedKillmail(8n)
  })

  it('a non-sponsor cannot create a killmail', async () => {
    const tx = new Transaction()
    createKillmail(tx, config, args(9n))
    await expectAbort(client, tx, player.toSuiAddress(), /EUnauthorizedSponsor/)
  })
})
