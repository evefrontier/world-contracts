/**
 * Build a deployment manifest (world.json) from `sui client publish --json` output.
 *
 * Captures what is NOT derivable on-chain: per-package ids/upgrade-caps, and the
 * shared objects created at publish time (e.g. the core ObjectRegistry, whose id and
 * initialSharedVersion every PTB needs). Clients (the SDK, seeding) read this file.
 *
 * Usage: tsx ts-scripts/build-manifest.ts <deployDir> <chainId> <pkg...>
 */
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

interface PublishedChange {
    type: "published";
    packageId: string;
    version: string;
}

interface CreatedChange {
    type: "created";
    objectId: string;
    objectType: string;
    owner: { Shared?: { initial_shared_version: number | string } } | unknown;
}

type ObjectChange = PublishedChange | CreatedChange | { type: string };

interface PublishOutput {
    objectChanges?: ObjectChange[];
}

interface PackageEntry {
    originalId: string;
    publishedAt: string;
    upgradeCap: string;
    version: number;
}

interface SharedObjectEntry {
    id: string;
    initialSharedVersion: string;
    type: string;
}

interface Manifest {
    chainId: string;
    packages: Record<string, PackageEntry>;
    sharedObjects: Record<string, SharedObjectEntry>;
}

const UPGRADE_CAP_TYPE = "0x2::package::UpgradeCap";

function isCreated(c: ObjectChange): c is CreatedChange {
    return c.type === "created";
}

function sharedVersion(owner: CreatedChange["owner"]): string | undefined {
    if (typeof owner === "object" && owner !== null && "Shared" in owner) {
        const v = (owner as { Shared?: { initial_shared_version?: number | string } }).Shared
            ?.initial_shared_version;
        return v === undefined ? undefined : String(v);
    }
    return undefined;
}

/** lower-camel key for a created shared object, from its `module::Struct` suffix. */
function sharedKey(objectType: string): string {
    const struct = objectType.split("::").pop() ?? objectType;
    return struct.charAt(0).toLowerCase() + struct.slice(1);
}

function main(): void {
    const [deployDir, chainId, ...packages] = process.argv.slice(2);
    if (!deployDir || !chainId || packages.length === 0) {
        console.error("Usage: tsx ts-scripts/build-manifest.ts <deployDir> <chainId> <pkg...>");
        process.exit(1);
    }

    const manifest: Manifest = { chainId, packages: {}, sharedObjects: {} };

    for (const pkg of packages) {
        const out: PublishOutput = JSON.parse(
            readFileSync(join(deployDir, `${pkg}.publish.json`), "utf8")
        );
        const changes = out.objectChanges ?? [];

        const published = changes.find((c): c is PublishedChange => c.type === "published");
        if (!published) throw new Error(`no published package in ${pkg}.publish.json`);

        const upgradeCap = changes.find(
            (c): c is CreatedChange => isCreated(c) && c.objectType === UPGRADE_CAP_TYPE
        );
        if (!upgradeCap) throw new Error(`no UpgradeCap created in ${pkg}.publish.json`);

        manifest.packages[pkg] = {
            // Fresh publish: original id, published-at and package id are identical.
            // Upgrades (real envs) will need to read published-at from Published.toml.
            originalId: published.packageId,
            publishedAt: published.packageId,
            upgradeCap: upgradeCap.objectId,
            version: Number(published.version),
        };

        // Record every shared object created at publish (e.g. the ObjectRegistry).
        for (const c of changes) {
            if (!isCreated(c)) continue;
            const v = sharedVersion(c.owner);
            if (v === undefined) continue;
            manifest.sharedObjects[sharedKey(c.objectType)] = {
                id: c.objectId,
                initialSharedVersion: v,
                type: c.objectType,
            };
        }
    }

    const path = join(deployDir, "world.json");
    writeFileSync(path, JSON.stringify(manifest, null, 2) + "\n");
    console.log(`Wrote ${path}`);
}

main();
