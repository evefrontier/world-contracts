import type { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519'
import { blake2b } from '@noble/hashes/blake2'

/** Sui PersonalMessage intent: scope 0x03, version 0, AppId::Sui. */
const PERSONAL_MESSAGE_INTENT = new Uint8Array([3, 0, 0])
const ED25519_FLAG = 0x00

/**
 * blake2b256 of `0x030000 || message`.
 * The message is raw bytes. It is not BCS-wrapped again.
 * Matches `core::sig_verify`.
 */
function personalMessageDigest(message: Uint8Array): Uint8Array {
  const intentMessage = new Uint8Array(
    PERSONAL_MESSAGE_INTENT.length + message.length,
  )
  intentMessage.set(PERSONAL_MESSAGE_INTENT, 0)
  intentMessage.set(message, PERSONAL_MESSAGE_INTENT.length)
  return blake2b(intentMessage, { dkLen: 32 })
}

/**
 * Ed25519 personal-message signature: `[0x00][signature][publicKey]`.
 * Matches `core::sig_verify::verify_signature`.
 */
export async function signPersonalMessage(
  message: Uint8Array,
  keypair: Ed25519Keypair,
): Promise<Uint8Array> {
  const signature = await keypair.sign(personalMessageDigest(message))
  const publicKey = keypair.getPublicKey().toRawBytes()
  const fullSignature = new Uint8Array(1 + signature.length + publicKey.length)
  fullSignature[0] = ED25519_FLAG
  fullSignature.set(signature, 1)
  fullSignature.set(publicKey, 1 + signature.length)
  return fullSignature
}
