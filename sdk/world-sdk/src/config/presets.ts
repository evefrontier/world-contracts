import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Env, SharedObjectRef, WorldConfig } from "./types.js";

interface WorldManifest {
    chainId: string;
    sharedObjects: Record<string, SharedObjectRef>;
}

// Deployment manifests are bundled into dist/presets/<env>.json by the build
// (scripts/copy-presets.ts copies deployments/<env>/world.json). Package ids
// resolve by MVR name at runtime, so only chainId + sharedObjects are needed.
const PRESETS_DIR = join(dirname(fileURLToPath(import.meta.url)), "../presets");

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
    let raw: string;
    try {
        raw = readFileSync(join(PRESETS_DIR, `${env}.json`), "utf8");
    } catch {
        throw new Error(`env "${env}" is not deployed yet (no preset config)`);
    }
    const manifest = JSON.parse(raw) as WorldManifest;
    return { env, chainId: manifest.chainId, sharedObjects: manifest.sharedObjects };
}
