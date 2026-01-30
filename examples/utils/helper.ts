import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { createClient, keypairFromPrivateKey } from "./client";
import { getConfig, MODULES, Network } from "./config";
import { TENANT } from "./constants";
export interface EnvConfig {
    network: Network;
    exportedKey: string;
    playerExportedKey?: string;
    playerAddress?: string;
    adminAddress?: string;
    tenant: string;
}

export interface InitializedContext {
    client: SuiClient;
    keypair: Ed25519Keypair;
    config: ReturnType<typeof getConfig>;
    address: string;
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

export function getEnvConfig(): EnvConfig {
    const network = (process.env.SUI_NETWORK as Network) || "localnet";
    const exportedKey = process.env.PRIVATE_KEY;
    const playerExportedKey =
        process.env.PLAYER_A_PRIVATE_KEY || process.env.PRIVATE_KEY || exportedKey;
    const playerAddress = process.env.PLAYER_A_ADDRESS || "";

    if (!exportedKey || !playerExportedKey) {
        throw new Error(
            "PRIVATE_KEY environment variable is required eg: PRIVATE_KEY=suiprivkey1..."
        );
    }

    return {
        network,
        exportedKey,
        playerExportedKey,
        playerAddress,
        tenant: TENANT,
    };
}

export function initializeContext(network: Network, privateKey: string): InitializedContext {
    const client = createClient(network);
    const keypair = keypairFromPrivateKey(privateKey);
    const config = getConfig(network);
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
    const adminAddress = process.env.ADMIN_ADDRESS;
    const type = `${packageId}::${MODULES.ACCESS}::AdminCap`;
    const res = await client.getOwnedObjects({
        owner: adminAddress!,
        filter: { StructType: type },
        limit: 1,
    });
    const first = res.data?.[0]?.data;
    return first?.objectId ?? null;
}
