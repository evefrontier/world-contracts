import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519'
import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import { eveCurrency } from '../config/shared-objects.js'
import { eveCoinType, transferEve } from '../packages/currency.js'
import {
  expectSuccess,
  loadLocalnetWorld,
  requirePackage,
  signer,
} from './helpers.js'

// Requires deploy-currency.sh (finalize:eve) so world.json has eveCurrency and
// the deployer holds the init EVE allocation.
const AMOUNT_RAW = 1_000_000_000n // 1 EVE

describe('EVE currency (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  it('finalize left Currency shared and recorded in the manifest', async () => {
    const packageId = requirePackage(config, 'currency')
    const ref = eveCurrency(config)
    expect(ref.type).toBe(
      `0x2::coin_registry::Currency<${packageId}::EVE::EVE>`,
    )

    const { object } = await client.getObject({ objectId: ref.id })
    expect(object.type).toBe(ref.type)
    expect(
      object.owner.$kind,
      'Currency is not shared (finalize incomplete?)',
    ).toBe('Shared')
  })

  it('transferEve moves balance to a recipient', async () => {
    const coinType = eveCoinType(config)
    const recipient = Ed25519Keypair.generate().toSuiAddress()

    const coins = await client.listCoins({
      owner: signer,
      coinType,
      limit: 1,
    })
    const coin = coins.objects[0]
    expect(coin, 'deployer has no EVE after currency deploy').toBeDefined()
    expect(BigInt(coin.balance)).toBeGreaterThanOrEqual(AMOUNT_RAW)

    const before = BigInt(coin.balance)
    const tx = new Transaction()
    transferEve(tx, {
      coin: coin.objectId,
      amountRaw: AMOUNT_RAW,
      recipient,
    })
    await expectSuccess(client, tx)

    const { balance: recipientBalance } = await client.getBalance({
      owner: recipient,
      coinType,
    })
    expect(BigInt(recipientBalance.balance)).toBe(AMOUNT_RAW)

    const { balance: senderBalance } = await client.getBalance({
      owner: signer,
      coinType,
    })
    expect(BigInt(senderBalance.balance)).toBe(before - AMOUNT_RAW)
  })
})
