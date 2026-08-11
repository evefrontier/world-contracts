import type { SharedObjectRef, WorldConfig } from './types.js'

// Must match a key in build-manifest.ts SHARED_OBJECT_KEYS.
// TODO: replace these per-object string keys with a full-type lookup
// (sharedObject(config, "module::Struct")) so new singletons need no constant here.
export const OBJECT_REGISTRY = 'objectRegistry'
export const ADMIN_ACL = 'adminAcl'
export const EVE_CURRENCY = 'eveCurrency'

/** Validate that an unknown value is a complete `SharedObjectRef`. */
export function parseSharedObjectRef(
  value: unknown,
  label: string,
): SharedObjectRef {
  const ref = value as Partial<SharedObjectRef> | undefined
  if (!ref?.id) throw new Error(`${label}: missing id`)
  if (!ref.type) throw new Error(`${label}: missing type`)
  return ref as SharedObjectRef
}

export function requireSharedObject(
  config: WorldConfig,
  name: string,
): SharedObjectRef {
  return parseSharedObjectRef(
    config.sharedObjects[name],
    `env "${config.env}" shared object "${name}"`,
  )
}

export function objectRegistry(config: WorldConfig): SharedObjectRef {
  return requireSharedObject(config, OBJECT_REGISTRY)
}

export function adminAcl(config: WorldConfig): SharedObjectRef {
  return requireSharedObject(config, ADMIN_ACL)
}

export function eveCurrency(config: WorldConfig): SharedObjectRef {
  return requireSharedObject(config, EVE_CURRENCY)
}
