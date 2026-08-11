import type { Transaction } from '@mysten/sui/transactions'
import { mvrName } from '../config/env.js'
import type { WorldConfig } from '../config/types.js'
import { completeRequest, entityNew, shareEntity, verifyAdmin } from './core.js'

const CHARACTER_PACKAGE = 'character'

export interface CreateCharacterArgs {
  inGameId: bigint
  tenant: string
  tribeId: number
  owner: string
}

/**
 * Append the full character-creation flow to `tx`: claim the entity, install the
 * identity module, and share it. Each lifecycle step is admin-gated, so the
 * transaction must be signed by a whitelisted admin.
 */
export function createCharacter(
  tx: Transaction,
  config: WorldConfig,
  args: CreateCharacterArgs,
): void {
  const [character, claimReq] = entityNew(tx, config, {
    inGameId: args.inGameId,
    tenant: args.tenant,
    locationHash: [],
  })
  verifyAdmin(tx, config, claimReq)
  completeRequest(tx, config, character, claimReq)

  const installReq = tx.moveCall({
    target: `${mvrName(config.env, CHARACTER_PACKAGE)}::identity::install`,
    arguments: [
      character,
      tx.pure.u32(args.tribeId),
      tx.pure.address(args.owner),
    ],
  })
  verifyAdmin(tx, config, installReq)
  completeRequest(tx, config, character, installReq)

  shareEntity(tx, config, character)
}
