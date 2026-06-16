import type { Env, WorldConfig } from "./types.js";
import { OBJECT_REGISTRY } from "./shared-objects.js";

const UNDEPLOYED = { id: "", initialSharedVersion: "0", type: "" };

// Populated by each env's deploy. Empty objectRegistry id => not deployed.
const PRESETS: Record<Exclude<Env, "local">, WorldConfig> = {
    dev: { env: "dev", chainId: "", sharedObjects: { [OBJECT_REGISTRY]: UNDEPLOYED } },
    uat: { env: "uat", chainId: "", sharedObjects: { [OBJECT_REGISTRY]: UNDEPLOYED } },
    test: { env: "test", chainId: "", sharedObjects: { [OBJECT_REGISTRY]: UNDEPLOYED } },
    live: { env: "live", chainId: "", sharedObjects: { [OBJECT_REGISTRY]: UNDEPLOYED } },
};

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
    const config = PRESETS[env];
    if (!config.sharedObjects[OBJECT_REGISTRY]?.id) {
        throw new Error(`env "${env}" is not deployed yet (no preset config)`);
    }
    return config;
}
