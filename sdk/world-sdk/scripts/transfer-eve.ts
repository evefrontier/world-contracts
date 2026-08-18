/**
 * Transfer EVE from the deployer (SUI_PRIVATE_KEY) to another address.
 *
 * Usage:
 *   ENV=localnet RECIPIENT=0x... AMOUNT=100 pnpm --filter @evefrontier/world-sdk transfer:eve
 * AMOUNT is whole EVE tokens (9 decimals), e.g. 100 = 100 EVE.
 */
import { Transaction } from '@mysten/sui/transactions'
import 'dotenv/config'
import { eveCoinType, transferEve } from '../src/packages/currency.js'
import { loadScriptContext } from './context.js'

const EVE_DECIMALS = 9
const SCALE = 10n ** BigInt(EVE_DECIMALS)

async function main(): Promise<void> {
  const recipient = process.env.RECIPIENT
  const amountStr = process.env.AMOUNT ?? '1'

  if (!recipient) {
    console.error('Set RECIPIENT.')
    process.exit(1)
  }

  if (!/^\d+$/.test(amountStr.trim())) {
    console.error('AMOUNT must be a positive whole number of EVE tokens.')
    process.exit(1)
  }
  const amountEve = BigInt(amountStr.trim())
  if (amountEve <= 0n) {
    console.error('AMOUNT must be a positive whole number of EVE tokens.')
    process.exit(1)
  }
  const amountRaw = amountEve * SCALE

  const { config, client, keypair } = loadScriptContext()
  const sender = keypair.getPublicKey().toSuiAddress()
  const coinType = eveCoinType(config)

  const coinsRes = await client.getCoins({
    owner: sender,
    coinType,
    limit: 1,
  })
  const coin = coinsRes.data[0]
  if (!coin) {
    console.error('Deployer has no EVE coins.')
    process.exit(1)
  }
  if (BigInt(coin.balance) < amountRaw) {
    console.error(
      `Insufficient balance. Have ${coin.balance} raw (~${BigInt(coin.balance) / SCALE} EVE), need ${amountRaw} raw (${amountEve} EVE).`,
    )
    process.exit(1)
  }

  const tx = new Transaction()
  transferEve(tx, {
    coin: coin.coinObjectId,
    amountRaw,
    recipient,
  })

  const result = await client.signAndExecuteTransaction({
    signer: keypair,
    transaction: tx,
    options: { showEffects: true },
  })

  if (result.effects?.status?.status === 'success') {
    console.log(`Transferred ${amountEve} EVE to ${recipient}`)
    console.log('Digest:', result.digest)
  } else {
    console.error('Transfer failed:', result.effects?.status)
    process.exit(1)
  }
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
