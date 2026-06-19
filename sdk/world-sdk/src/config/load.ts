import { readFileSync } from "node:fs";
import type { SharedObjectRef, WorldConfig } from "./types.js";
import { OBJECT_REGISTRY, parseSharedObjectRef } from "./shared-objects.js";

interface WorldManifest {
    chainId: string;
    packages: Record<string, { publishedAt: string }>;
    sharedObjects: Record<string, SharedObjectRef>;
}

/**
 * Read a generated `world.json` into a `WorldConfig`. Node-only, for local/CI:
 * the chain is ephemeral and packages have no MVR registry, so the manifest's
 * package IDs become `packageOverrides`. Always sets `env` to `"local"`.
 */
export function loadWorldConfig(path: string): WorldConfig {
    let raw: string;
    try {
        raw = readFileSync(path, "utf8");
    } catch (err) {
        throw new Error(`world config not found at ${path}: ${(err as Error).message}`);
    }

    let manifest: Partial<WorldManifest>;
    try {
        manifest = JSON.parse(raw) as Partial<WorldManifest>;
    } catch (err) {
        throw new Error(`${path}: invalid JSON: ${(err as Error).message}`);
    }
    if (!manifest.chainId) throw new Error(`${path}: missing chainId`);

    const sharedObjects = manifest.sharedObjects ?? {};
    parseSharedObjectRef(sharedObjects[OBJECT_REGISTRY], `${path}: sharedObjects.${OBJECT_REGISTRY}`);

    const packageOverrides: Record<string, string> = {};
    for (const [pkg, entry] of Object.entries(manifest.packages ?? {})) {
        if (!entry.publishedAt) throw new Error(`${path}: package "${pkg}" missing publishedAt`);
        packageOverrides[pkg] = entry.publishedAt;
    }

    return {
        env: "local",
        chainId: manifest.chainId,
        sharedObjects,
        packageOverrides,
    };
}
