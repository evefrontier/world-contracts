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

/** Must match `core::docking::Docking` in Move. */
const Docking = bcs.struct('Docking', {
  ship: bcs.Address,
  target: bcs.Address,
  character: bcs.Address,
})

export interface ProofMessageArgs {
  /** Only this address may submit the proof. */
  sender: string
  deadlineMs: bigint
  server?: string
}

export interface DockingArgs extends ProofMessageArgs {
  ship: string
  target: string
  character: string
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
  signature: Uint8Array = new Uint8Array(),
): Uint8Array {
  const message = ProofMessage.serialize({
    server: args.server ?? normalizeSuiAddress('0x0'),
    sender: args.sender,
    kind: Array.from(new TextEncoder().encode(kind)),
    deadline_ms: args.deadlineMs,
    payload: Array.from(payload),
  }).toBytes()
  const sig = bcs.vector(bcs.u8()).serialize(Array.from(signature)).toBytes()
  const bytes = new Uint8Array(message.length + sig.length)
  bytes.set(message, 0)
  bytes.set(sig, message.length)
  return bytes
}

/** An unsigned docking proof */
export function dockingProof(
  config: WorldConfig,
  args: DockingArgs,
): Uint8Array {
  const payload = Docking.serialize({
    ship: args.ship,
    target: args.target,
    character: args.character,
  }).toBytes()
  return encodeProof(proofKind(config, 'docking', 'Docking'), payload, args)
}
