import type { SharedObjectRef, WorldConfig } from "./types.js";

// Must match a key in build-manifest.ts SHARED_OBJECT_KEYS.
// TODO: replace these per-object string keys with a full-type lookup
// (sharedObject(config, "module::Struct")) so new singletons need no constant here.
export const OBJECT_REGISTRY = "objectRegistry";

export function requireSharedObject(config: WorldConfig, name: string): SharedObjectRef {
    const ref = config.sharedObjects[name];
    if (!ref?.id) {
        throw new Error(`env "${config.env}" has no shared object "${name}"`);
    }
    return ref;
}

export function objectRegistry(config: WorldConfig): SharedObjectRef {
    return requireSharedObject(config, OBJECT_REGISTRY);
}
