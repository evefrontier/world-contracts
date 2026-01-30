import "dotenv/config";
import { bcs } from "@mysten/sui/bcs";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import { NWN_ITEM_ID, ASSEMBLY_ITEM_ID, GAME_CHARACTER_ID } from "../utils/constants";
import { initializeContext, handleError, getEnvConfig } from "../utils/helper";

export async function online(
    networkObjectId: string,
    assemblyId: string,
    ownerCapId: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Bringing Assembly Online ====");

    const characterId = deriveObjectId(config.objectRegistry, GAME_CHARACTER_ID, config.packageId);

    const tx = new Transaction();

    // 1. Borrow OwnerCap from character (Receiving ticket = object ref of OwnerCap owned by character)
    const [ownerCap] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.ASSEMBLY}::Assembly`],
        arguments: [tx.object(characterId), tx.object(ownerCapId)],
    });

    // 2. Use the borrowed OwnerCap to bring the assembly online
    tx.moveCall({
        target: `${config.packageId}::${MODULES.ASSEMBLY}::online`,
        arguments: [
            tx.object(assemblyId),
            tx.object(networkObjectId),
            tx.object(config.energyConfig),
            ownerCap,
        ],
    });

    // 3. Return the OwnerCap to the character
    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.ASSEMBLY}::Assembly`],
        arguments: [tx.object(characterId), ownerCap],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log("\n Assembly brought online successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

export async function getOwnerCap(
    assemblyId: string,
    client: SuiClient,
    config: ReturnType<typeof getConfig>,
    senderAddress?: string
): Promise<string | null> {
    try {
        const tx = new Transaction();

        tx.moveCall({
            target: `${config.packageId}::${MODULES.ASSEMBLY}::owner_cap_id`,
            arguments: [tx.object(assemblyId)],
        });

        const result = await client.devInspectTransactionBlock({
            sender: senderAddress || process.env.ADMIN_ADDRESS || "0x",
            transactionBlock: tx,
        });

        if (result.effects?.status?.status !== "success") {
            console.warn("Error checking ownercap id:", result.effects?.status?.error);
            return null;
        }
        const returnValues = result.results?.[0]?.returnValues;

        if (returnValues && returnValues.length > 0) {
            const [valueBytes] = returnValues[0];
            const ownerCapId = bcs.Address.parse(Uint8Array.from(valueBytes));
            return ownerCapId;
        }

        return null;
    } catch (error) {
        console.warn("Failed to get ownerCap:", error instanceof Error ? error.message : error);
        return null;
    }
}

async function main() {
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.playerExportedKey!);
        const { client, keypair, config } = ctx;

        let networkNodeObject = deriveObjectId(
            config.objectRegistry,
            NWN_ITEM_ID,
            config.packageId
        );

        let assemblyObject = deriveObjectId(
            config.objectRegistry,
            ASSEMBLY_ITEM_ID,
            config.packageId
        );

        let assemblyOwnerCap = await getOwnerCap(assemblyObject, client, config, env.playerAddress);
        if (!assemblyOwnerCap) {
            throw new Error(`OwnerCap not found for ${assemblyObject}`);
        }

        await online(networkNodeObject, assemblyObject, assemblyOwnerCap, client, keypair, config);
    } catch (error) {
        handleError(error);
    }
}

main().catch(console.error);
