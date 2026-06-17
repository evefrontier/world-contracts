/**
 * Build a deployment manifest (world.json) from a deploy.
 *
 * Package ids/upgrade-caps come from the canonical source per env: localnet
 * derives them from `sui client test-publish` JSON; named envs (dev/test/uat/live)
 * read the committed contracts/<pkg>/Published.toml [published.<env>], so upgrades
 * (which reuse the UpgradeCap and create nothing) work too. Shared objects (e.g.
 * the core ObjectRegistry) are read from publish JSON when present and otherwise
 * preserved from the existing manifest.
 *
 * Usage: tsx ts-scripts/build-manifest.ts <deployDir> <env> <chainId> <pkg...>
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parse as parseToml } from "@iarna/toml";

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

interface MvrEntry {
    name: string;
    packageInfo?: string;
    appCap?: string;
}

interface Manifest {
    chainId: string;
    packages: Record<string, PackageEntry>;
    sharedObjects: Record<string, SharedObjectEntry>;
    mvr?: Record<string, MvrEntry>;
}

const UPGRADE_CAP_TYPE = "0x2::package::UpgradeCap";

// Known deploy-time singleton shared objects keyed by struct suffix `module::Struct`
// (package-id agnostic) -> stable manifest key the SDK looks up (sdk shared-objects.ts).
// Anything not listed is intentionally not surfaced (e.g. per-entity runtime objects).
// Each new singleton needs a line here. Keep in sync with the SDK constant.
// TODO: drop this map and key sharedObjects by full `pkg::module::Struct` once the SDK
// lookup API moves from objectRegistry(config) to sharedObject(config, "module::Struct").
const SHARED_OBJECT_KEYS: Record<string, string> = {
    "object_registry::ObjectRegistry": "objectRegistry",
};

function isCreated(c: ObjectChange): c is CreatedChange {
    return c.type === "created";
}

function sharedVersion(owner: CreatedChange["owner"]): string | undefined {
    if (typeof owner === "object" && owner !== null && "Shared" in owner) {
        const v = (owner as { Shared?: { initial_shared_version?: number | string | null } }).Shared
            ?.initial_shared_version;
        if (v === undefined || v === null) return undefined;
        if (typeof v === "number" && Number.isFinite(v) && v >= 0) return String(v);
        if (typeof v === "string" && /^\d+$/.test(v)) return v;
        throw new Error(`invalid initial_shared_version: ${String(v)}`);
    }
    return undefined;
}

/** Manifest key for a created shared object, or undefined if it isn't a known one. */
function sharedKey(objectType: string): string | undefined {
    const suffix = objectType.split("::").slice(-2).join("::");
    return SHARED_OBJECT_KEYS[suffix];
}

function readPublishJson(deployDir: string, pkg: string): ObjectChange[] {
    const out = JSON.parse(readFileSync(join(deployDir, `${pkg}.publish.json`), "utf8")) as {
        objectChanges?: ObjectChange[];
    };
    return out.objectChanges ?? [];
}

/** Package entry from test-publish JSON (localnet: original publish, cap created). */
function packageFromPublishJson(deployDir: string, pkg: string): PackageEntry {
    const changes = readPublishJson(deployDir, pkg);
    const published = changes.find((c): c is PublishedChange => c.type === "published");
    if (!published) throw new Error(`no published package in ${pkg}.publish.json`);
    const upgradeCap = changes.find(
        (c): c is CreatedChange => isCreated(c) && c.objectType === UPGRADE_CAP_TYPE
    );
    if (!upgradeCap) throw new Error(`no UpgradeCap created in ${pkg}.publish.json`);
    return {
        originalId: published.packageId,
        publishedAt: published.packageId,
        upgradeCap: upgradeCap.objectId,
        version: Number(published.version),
    };
}

/** Package entry from the committed Published.toml [published.<env>] block. */
function packageFromPublishedToml(pkg: string, env: string): PackageEntry {
    const path = join("contracts", pkg, "Published.toml");
    const toml = parseToml(readFileSync(path, "utf8")) as {
        published?: Record<string, Record<string, unknown>>;
    };
    const block = toml.published?.[env];
    if (!block) throw new Error(`${path}: no [published.${env}]`);
    const need = (k: string): string => {
        const v = block[k];
        if (v === undefined || v === null) throw new Error(`${path} [published.${env}]: missing ${k}`);
        return String(v);
    };
    return {
        originalId: need("original-id"),
        publishedAt: need("published-at"),
        upgradeCap: need("upgrade-capability"),
        version: Number(need("version")),
    };
}

function addSharedObjects(changes: ObjectChange[], into: Record<string, SharedObjectEntry>): void {
    for (const c of changes) {
        if (!isCreated(c)) continue;
        const key = sharedKey(c.objectType);
        if (key === undefined) continue;
        const v = sharedVersion(c.owner);
        if (v === undefined) continue;
        into[key] = { id: c.objectId, initialSharedVersion: v, type: c.objectType };
    }
}

function main(): void {
    const [deployDir, env, chainId, ...packages] = process.argv.slice(2);
    if (!deployDir || !env || !chainId || packages.length === 0) {
        console.error("Usage: tsx ts-scripts/build-manifest.ts <deployDir> <env> <chainId> <pkg...>");
        process.exit(1);
    }

    const existingPath = join(deployDir, "world.json");
    const existing: Partial<Manifest> = existsSync(existingPath)
        ? (JSON.parse(readFileSync(existingPath, "utf8")) as Partial<Manifest>)
        : {};

    const manifest: Manifest = {
        chainId,
        packages: {},
        sharedObjects: existing.sharedObjects ?? {},
        ...(existing.mvr ? { mvr: existing.mvr } : {}),
    };

    for (const pkg of packages) {
        manifest.packages[pkg] =
            env === "localnet"
                ? packageFromPublishJson(deployDir, pkg)
                : packageFromPublishedToml(pkg, env);
        if (existsSync(join(deployDir, `${pkg}.publish.json`))) {
            addSharedObjects(readPublishJson(deployDir, pkg), manifest.sharedObjects);
        }
    }

    writeFileSync(existingPath, JSON.stringify(manifest, null, 2) + "\n");
    console.log(`Wrote ${existingPath}`);
}

main();
