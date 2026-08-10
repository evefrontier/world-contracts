import type {
  Transaction,
  TransactionObjectArgument,
} from '@mysten/sui/transactions'
import { mvrName } from '../config/env.js'
import type { WorldConfig } from '../config/types.js'

const CURRENCY_PACKAGE = 'currency'

export function currencyPackage(config: WorldConfig): string {
  return (
    config.packageOverrides?.[CURRENCY_PACKAGE] ??
    mvrName(config.env, CURRENCY_PACKAGE)
  )
}

export function eveCoinType(config: WorldConfig): string {
  return `${currencyPackage(config)}::EVE::EVE`
}

export interface TransferEveArgs {
  coin: string | TransactionObjectArgument
  amountRaw: bigint | number | string
  recipient: string
}

/** Split `amountRaw` from an EVE coin and transfer it to `recipient`. */
export function transferEve(tx: Transaction, args: TransferEveArgs): void {
  const coin = typeof args.coin === 'string' ? tx.object(args.coin) : args.coin
  const [toSend] = tx.splitCoins(coin, [args.amountRaw])
  tx.transferObjects([toSend], args.recipient)
}
