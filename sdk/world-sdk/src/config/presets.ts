import type { Env, SharedObjectRef, WorldConfig } from "./types.js";
import presets from "./presets.json" with { type: "json" };

// presets.json is maintained by ts-scripts/build-manifest.ts on each deploy:
// the per-env chainId + sharedObjects projected from deployments/<env>/world.json.
// Package ids resolve by MVR name at runtime, so they aren't carried here.
type Preset = { chainId: string; sharedObjects: Record<string, SharedObjectRef> };
const PRESETS = presets as Partial<Record<Exclude<Env, "local">, Preset>>;

/**
 * The config shipped with the SDK for a published env. Throws for `local`
 * (load it from a world.json via loadWorldConfig) and for undeployed envs.
 */
export function getWorldConfig(env: Env): WorldConfig {
    if (env === "local") {
        throw new Error(
            `env "local" has no preset config; load it from a world.json via loadWorldConfig`
        );
    }
    const preset = PRESETS[env];
    if (!preset) throw new Error(`env "${env}" is not deployed yet (no preset config)`);
    return { env, chainId: preset.chainId, sharedObjects: preset.sharedObjects };
}
