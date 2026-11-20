import { bcs } from '@mysten/sui/bcs'
import { normalizeSuiAddress } from '@mysten/sui/utils'
import { objectRegistry } from '../config/shared-objects.js'
import type { WorldConfig } from '../config/types.js'

/** Must match `core::proof::ProofMessage` in Move. */
const ProofMessage = bcs.struct('ProofMessage', {
  server: bcs.Address,
  sender: bcs.Address,
  kind: bcs.vector(bcs.u8()),
  deadline_ms: bcs.u64(),
  payload: bcs.vector(bcs.u8()),
})

export interface ProofMessageArgs {
  /** Address that signed the proof. Must match the signature's public key. */
  server: string
  /** Only this address may submit the proof. */
  sender: string
  deadlineMs: bigint
}

/**
 * The `type_name` Move records for a proof struct
 */
export function proofKind(
  config: WorldConfig,
  module: string,
  struct: string,
): string {
  const coreId = normalizeSuiAddress(objectRegistry(config).type.split('::')[0])
  return `${coreId.slice(2)}::${module}::${struct}`
}

/** Encode proof bytes: `bcs(ProofMessage) || bcs(signature)`. */
export function encodeProof(
  kind: string,
  payload: Uint8Array,
  args: ProofMessageArgs,
  signature: Uint8Array,
): Uint8Array {
  const message = messageBytes(kind, payload, args)
  const encodedSignature = bcs
    .vector(bcs.u8())
    .serialize(Array.from(signature))
    .toBytes()
  const proofBytes = new Uint8Array(message.length + encodedSignature.length)
  proofBytes.set(message, 0)
  proofBytes.set(encodedSignature, message.length)
  return proofBytes
}

function messageBytes(
  kind: string,
  payload: Uint8Array,
  args: ProofMessageArgs,
): Uint8Array {
  return ProofMessage.serialize({
    server: args.server,
    sender: args.sender,
    kind: Array.from(new TextEncoder().encode(kind)),
    deadline_ms: args.deadlineMs,
    payload: Array.from(payload),
  }).toBytes()
}
