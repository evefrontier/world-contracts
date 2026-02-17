import * as fs from "node:fs";
import * as path from "node:path";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { createClient, keypairFromPrivateKey } from "./client";
import {
    HydratedWorldConfig,
    WorldConfig,
    getConfig,
    MODULES,
    Network,
    DEFAULT_RPC_URLS,
    ExtractedObjectIds,
} from "./config";
import { TENANT } from "./constants";
import { getExtractedObjectIdsPath } from "./world-object-ids";
export interface EnvConfig {
    network: Network;
    rpcUrl: string;
    packageId: string;
    adminExportedKey: string;
    tenant: string;
}

export interface InitializedContext {
    client: SuiClient;
    keypair: Ed25519Keypair;
    config: WorldConfig;
    address: string;
}

type PublishObjectChange = {
    type?: string;
    packageId?: string;
    objectType?: string;
    objectId?: string;
    owner?: { AddressOwner?: string } | unknown;
};

// Parse arrays from environment variables
export function parseBigIntArray(
    envVar: string | undefined,
    defaultValue: bigint[] = []
): bigint[] {
    if (!envVar) return defaultValue;
    return envVar
        .split(",")
        .map((val) => BigInt(val.trim()))
        .filter((val) => val > 0n);
}

export function hexToBytes(hexString: string): Uint8Array {
    const hex = hexString.startsWith("0x") ? hexString.slice(2) : hexString;
    const normalizedHex = hex.length % 2 === 0 ? hex : "0" + hex;

    const bytes = new Uint8Array(normalizedHex.length / 2);
    for (let i = 0; i < normalizedHex.length; i += 2) {
        bytes[i / 2] = parseInt(normalizedHex.substring(i, i + 2), 16);
    }
    return bytes;
}

export function toHex(bytes: Uint8Array): string {
    return (
        "0x" +
        Array.from(bytes)
            .map((b) => b.toString(16).padStart(2, "0"))
            .join("")
    );
}

export function fromHex(hex: string): Uint8Array {
    const cleanHex = hex.startsWith("0x") ? hex.slice(2) : hex;

    const bytes = new Uint8Array(cleanHex.length / 2);
    for (let i = 0; i < cleanHex.length; i += 2) {
        bytes[i / 2] = parseInt(cleanHex.slice(i, i + 2), 16);
    }

    return bytes;
}

export function handleError(error: unknown): never {
    console.error("\n=== Error ===");
    console.error("Error:", error instanceof Error ? error.message : error);
    if (error instanceof Error && error.stack) {
        console.error("Stack:", error.stack);
    }
    process.exit(1);
}

export function requireEnv(name: string): string {
    const value = process.env[name];
    if (!value) throw new Error(`${name} is required`);
    return value;
}

export function getEnvConfig(): EnvConfig {
    const network = (process.env.SUI_NETWORK as Network) || "localnet";
    const rpcUrl = process.env.SUI_RPC_URL || DEFAULT_RPC_URLS[network];
    const packageId = getDefaultWorldPackageId(network);
    if (!packageId) {
        throw new Error("WORLD_PACKAGE_ID is required");
    }
    const adminExportedKey = requireEnv("ADMIN_PRIVATE_KEY");

    process.env.SUI_RPC_URL = rpcUrl;

    return {
        network,
        rpcUrl,
        packageId,
        adminExportedKey,
        tenant: TENANT,
    };
}

export function initializeContext(network: Network, privateKey: string): InitializedContext {
    const client = createClient(network);
    const keypair = keypairFromPrivateKey(privateKey);
    const config = getConfig(network) as WorldConfig;
    const fromExtracted = getDefaultWorldPackageId(network);
    if (fromExtracted) config.packageId = fromExtracted;
    const address = keypair.getPublicKey().toSuiAddress();

    return { client, keypair, config, address };
}

export function extractEvent<T = unknown>(
    result: { events?: Array<{ type: string; parsedJson?: unknown }> | null | undefined },
    eventTypeSuffix: string
): T | null {
    const events = result.events || [];
    const event = events.find((event) => event.type.endsWith(eventTypeSuffix));
    return (event?.parsedJson as T) || null;
}

export async function getAdminCapId(client: SuiClient, packageId: string): Promise<string | null> {
    const adminAddress = requireEnv("ADMIN_ADDRESS");
    const type = `${packageId}::${MODULES.ACCESS}::AdminCap`;
    const res = await client.getOwnedObjects({
        owner: adminAddress,
        filter: { StructType: type },
        limit: 1,
    });
    const first = res.data?.[0]?.data;
    return first?.objectId ?? null;
}

export async function hydrateWorldConfig(ctx: InitializedContext): Promise<HydratedWorldConfig> {
    const hasManualIds =
        !!ctx.config.governorCap &&
        !!ctx.config.serverAddressRegistry &&
        !!ctx.config.objectRegistry &&
        !!ctx.config.adminAcl &&
        !!ctx.config.energyConfig &&
        !!ctx.config.fuelConfig &&
        !!ctx.config.gateConfig;

    if (!hasManualIds) {
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const extracted = loadExtractedObjectIds(network);
        if (!extracted?.world || extracted.world.packageId !== ctx.config.packageId) {
            const filePath = getExtractedObjectIdsPath(network);
            throw new Error(
                `Missing or mismatched ${filePath}. Run \`npm run extract-object-ids\` after deploy.`
            );
        }
        const { packageId: _p, ...ids } = extracted.world;
        ctx.config = { ...ctx.config, ...ids } as WorldConfig;
    }

    return ctx.config as HydratedWorldConfig;
}

/**
 * When a admin/player contexts target the same network + package, hydrate once,
 * then reuse the same hydrated config object.
 */
export function shareHydratedConfig(from: InitializedContext, to: InitializedContext) {
    to.config = from.config;
}

export function resolvePublishOutputPath(relativePath: string): string {
    return path.resolve(process.cwd(), relativePath);
}

export function loadExtractedObjectIds(network: string): ExtractedObjectIds | null {
    const filePath = getExtractedObjectIdsPath(network);
    if (!fs.existsSync(filePath)) return null;
    try {
        const raw = fs.readFileSync(filePath, "utf8");
        return JSON.parse(raw) as ExtractedObjectIds;
    } catch {
        return null; // invalid JSON or read error
    }
}

export function getDefaultWorldPackageId(network: string): string {
    return process.env.WORLD_PACKAGE_ID || loadExtractedObjectIds(network)?.world?.packageId || "";
}

export function getDefaultBuilderPackageId(network: string): string {
    return (
        process.env.BUILDER_PACKAGE_ID || loadExtractedObjectIds(network)?.builder?.packageId || ""
    );
}

export function readPublishOutputFile(filePath: string): { objectChanges: PublishObjectChange[] } {
    const raw = fs.readFileSync(filePath, "utf8");
    let parsed: { objectChanges?: unknown; effects?: { objectChanges?: unknown } };
    try {
        parsed = JSON.parse(raw) as typeof parsed;
    } catch {
        throw new Error(`Invalid JSON in ${filePath}`);
    }

    const objectChanges = Array.isArray(parsed.objectChanges)
        ? parsed.objectChanges
        : Array.isArray(parsed.effects?.objectChanges)
          ? parsed.effects.objectChanges
          : undefined;

    if (!objectChanges) {
        throw new Error(`Invalid publish output file (missing objectChanges[]): ${filePath}`);
    }

    return { objectChanges: objectChanges as PublishObjectChange[] };
}

export function getPublishedPackageId(changes: PublishObjectChange[]): string {
    const published = changes.find((c) => c?.type === "published");
    if (typeof published?.packageId !== "string") {
        throw new Error("Publish output missing published packageId");
    }
    return published.packageId;
}

// TODO: use grpc query the object id instead of the publish output file
export function findCreatedObjectId(
    changes: PublishObjectChange[],
    objectType: string,
    opts?: { addressOwner?: string }
): string | undefined {
    for (const c of changes) {
        if (c?.type !== "created") continue;
        if (c?.objectType !== objectType) continue;
        if (typeof c?.objectId !== "string") continue;

        if (opts?.addressOwner) {
            const owner = c.owner as any;
            if (owner?.AddressOwner !== opts.addressOwner) continue;
        }

        return c.objectId;
    }
}

export function requireId(label: string, id: string | undefined): string {
    if (!id) throw new Error(`${label} not found`);
    return id;
}

export function typeName(packageId: string, moduleName: string, structName: string): string {
    return `${packageId}::${moduleName}::${structName}`;
}
