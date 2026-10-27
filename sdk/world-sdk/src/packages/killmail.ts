import type { Transaction } from '@mysten/sui/transactions'
import { mvrName } from '../config/env.js'
import type { WorldConfig } from '../config/types.js'
import {
  completeRequest,
  deriveObjectId,
  entityNew,
  shareEntity,
  verifyAdmin,
} from './core.js'

const KILLMAIL_PACKAGE = 'killmail'

/** Must match `record::loss_type_from_u8` in Move (the game's proto LossType). */
export const LOSS_TYPE_SHIP = 1 as const
export const LOSS_TYPE_STRUCTURE = 2 as const

export type LossType = typeof LOSS_TYPE_SHIP | typeof LOSS_TYPE_STRUCTURE

export interface KillmailArgs {
  inGameId: bigint
  tenant: string
  reporterId: bigint
  killerId: bigint
  victimId: bigint
  lossType: LossType
  solarSystemId: bigint
  killTime: bigint
}

/**
 * Append the full killmail-creation flow to `tx`: claim the entity, install the
 * killmail module, and share it. Each lifecycle step is admin-gated, so the
 * transaction must be signed by a whitelisted admin.
 */
export function createKillmail(
  tx: Transaction,
  config: WorldConfig,
  args: KillmailArgs,
): void {
  const [killmail, claimReq] = entityNew(tx, config, {
    inGameId: args.inGameId,
    tenant: args.tenant,
  })

  verifyAdmin(tx, config, claimReq)
  completeRequest(tx, config, killmail, claimReq)

  const reporter = tx.object(
    deriveObjectId(config, { id: args.reporterId, tenant: args.tenant }),
  )

  const installReq = tx.moveCall({
    target: `${mvrName(config.env, KILLMAIL_PACKAGE)}::record::install`,
    arguments: [
      killmail,
      reporter,
      tx.pure.u64(args.killerId),
      tx.pure.u64(args.victimId),
      tx.pure.u64(args.killTime),
      tx.pure.u8(args.lossType),
      tx.pure.u64(args.solarSystemId),
    ],
  })
  verifyAdmin(tx, config, installReq)
  completeRequest(tx, config, killmail, installReq)

  shareEntity(tx, config, killmail)
}
