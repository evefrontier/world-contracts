/**
 * Sign Sui transactions with an AWS KMS key. The private key never leaves KMS.
 *
 * AWS credentials come from the standard provider chain (env vars set by
 * GitHub OIDC, AWS_PROFILE / SSO locally). Region from AWS_REGION or the key ARN.
 *
 * Usage:
 *   tsx ts-scripts/kms-signer.ts address <keyId>            # print the key's Sui address
 *   tsx ts-scripts/kms-signer.ts sign <keyId> <txBytesB64>  # print a serialized signature
 */
import { fromNodeProviderChain } from '@aws-sdk/credential-providers'
import { AwsKmsSigner } from '@mysten/aws-kms-signer'
import { fromBase64 } from '@mysten/sui/utils'

function regionFor(keyId: string): string {
  const region =
    process.env.AWS_REGION ??
    process.env.AWS_DEFAULT_REGION ??
    (keyId.startsWith('arn:aws:kms:') ? keyId.split(':')[3] : undefined)
  if (!region) throw new Error('Set AWS_REGION or use a full KMS key ARN')
  return region
}

async function main() {
  const [cmd, keyId, txBytes] = process.argv.slice(2)
  if (!keyId || (cmd !== 'address' && cmd !== 'sign')) {
    console.error(
      'Usage: kms-signer.ts address <keyId> | sign <keyId> <txBytesB64>',
    )
    process.exit(1)
  }
  const signer = await AwsKmsSigner.fromKeyId(keyId, {
    region: regionFor(keyId),
    credentials: fromNodeProviderChain(),
  })
  if (cmd === 'address') {
    console.log(signer.toSuiAddress())
    return
  }
  if (!txBytes) throw new Error('sign: missing <txBytesB64>')
  const { signature } = await signer.signTransaction(fromBase64(txBytes))
  console.log(signature)
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e)
  process.exit(1)
})
