export type Env = 'local' | 'dev' | 'uat' | 'test' | 'live'

export type Network = 'localnet' | 'testnet' | 'mainnet'

export interface SharedObjectRef {
  id: string
  initialSharedVersion?: string
  type: string
}

/**
 * Data the SDK can't get from an MVR name: the target chain and shared objects.
 * Package IDs resolve by MVR name, except on `local` where `packageOverrides`
 * (short package name -> published id) feeds the resolver.
 */
export interface WorldConfig {
  env: Env
  chainId: string
  sharedObjects: Record<string, SharedObjectRef>
  packageOverrides?: Record<string, string>
}
