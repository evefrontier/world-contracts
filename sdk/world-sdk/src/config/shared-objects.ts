import type { SharedObjectRef, WorldConfig } from "./types.js";

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
