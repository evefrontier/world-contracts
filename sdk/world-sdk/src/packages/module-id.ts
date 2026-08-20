import { blake2b } from '@noble/hashes/blake2b'

/** Matches `core::mod::id_from_name`: first 8 bytes (LE) of `blake2b256(utf8(name))`. */
export function moduleIdFromName(name: string): bigint {
  const digest = blake2b(new TextEncoder().encode(name), { dkLen: 32 })
  const view = new DataView(digest.buffer, digest.byteOffset, digest.byteLength)
  return view.getBigUint64(0, true)
}
