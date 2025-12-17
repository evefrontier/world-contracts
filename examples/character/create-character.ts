import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";
import { deriveCharacterId } from "./derive-character-id";

const GAME_CHARACTER_ID = Math.floor(Math.random() * 1000000) + 1;
const TRIBE_ID = 100;

async function createCharacter(
    tenant: string,
    characterAddress: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
): Promise<string> {
    console.log("\n==== Creating a character ====");
    console.log("Game Character ID:", GAME_CHARACTER_ID);
    console.log("Tribe ID:", TRIBE_ID);
    console.log("TENANT:", tenant);

    // Pre-compute the character ID before creation
    const precomputedCharacterId = deriveCharacterId(
        config.characterRegisterId,
        GAME_CHARACTER_ID,
        tenant,
        config.packageId
    );
    console.log("Pre-computed Character ID:", precomputedCharacterId);

    const tx = new Transaction();
    const [character] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::create_character`,
        arguments: [
            tx.object(config.characterRegisterId),
            tx.object(config.adminCapObjectId),
            tx.pure.u32(GAME_CHARACTER_ID),
            tx.pure.string(tenant),
            tx.pure.u32(TRIBE_ID),
            tx.pure.address(characterAddress),
            tx.pure.string("frontier-character-a"),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::share_character`,
        arguments: [character, tx.object(config.adminCapObjectId)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true },
    });

    console.log(result);

    // object id of the character
    const characterId = result.objectChanges?.find((change) => change.type === "created")?.objectId;
    if (!characterId) {
        throw new Error("Failed to create character and object id was not found");
    }

    console.log("Character created", characterId);
    return characterId;
}

async function main() {
    console.log("============= Create Character example ==============\n");

    try {
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PRIVATE_KEY;
        const playerAddress = process.env.PLAYER_A_ADDRESS || "";
        const tenant = process.env.TENANT || "";

        if (!exportedKey) {
            throw new Error(
                "PRIVATE_KEY environment variable is required eg: PRIVATE_KEY=suiprivkey1..."
            );
        }

        const client = createClient(network);
        const keypair = keypairFromPrivateKey(exportedKey);
        const config = getConfig(network);

        await createCharacter(tenant, playerAddress, client, keypair, config);
    } catch (error) {
        console.error("\n=== Error ===");
        console.error("Error:", error instanceof Error ? error.message : error);
        if (error instanceof Error && error.stack) {
            console.error("Stack:", error.stack);
        }
        process.exit(1);
    }
}

main().catch(console.error);
