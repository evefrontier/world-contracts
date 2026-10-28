import { bcs } from '@mysten/sui/bcs'
import type { Transaction } from '@mysten/sui/transactions'
import { blake2b } from '@noble/hashes/blake2'
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
  killTime: Date
}

const KILLMAIL_ID_SUFFIX = new TextEncoder().encode('killmail')

/**
 * Entity id for a killmail: first 8 bytes (LE) of `blake2b256(bcs(u64 inGameId) ++ "killmail")`.
 * Namespaces killmail ids so they can't collide with other entities' game ids.
 */
export function killmailId(inGameId: bigint): bigint {
  const idBytes = bcs.u64().serialize(inGameId).toBytes()
  const input = new Uint8Array(idBytes.length + KILLMAIL_ID_SUFFIX.length)
  input.set(idBytes)
  input.set(KILLMAIL_ID_SUFFIX, idBytes.length)
  const digest = blake2b(input, { dkLen: 32 })
  const view = new DataView(digest.buffer, digest.byteOffset, digest.byteLength)
  return view.getBigUint64(0, true)
}

/**
 * Converts a Date to milliseconds
 * @param killTime
 * @returns Date as milliseconds (u64)
 */
function convertDateToMilliseconds(killTime: Date): bigint {
  return BigInt(Math.floor(killTime.getTime() / 1000))
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
    inGameId: killmailId(args.inGameId),
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
      tx.pure.u64(convertDateToMilliseconds(args.killTime)),
      tx.pure.u8(args.lossType),
      tx.pure.u64(args.solarSystemId),
    ],
  })
  verifyAdmin(tx, config, installReq)
  completeRequest(tx, config, killmail, installReq)

  shareEntity(tx, config, killmail)
}
