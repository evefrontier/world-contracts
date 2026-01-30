import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { initializeContext, handleError, getEnvConfig, getAdminCapId } from "../utils/helper";
import { MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import { GAME_CHARACTER_ID } from "../utils/constants";

const TRIBE_ID = 100;

async function createCharacter(
    tenant: string,
    characterAddress: string,
    ctx: ReturnType<typeof initializeContext>
): Promise<string> {
    const { client, keypair, config } = ctx;
    const adminCap = await getAdminCapId(client, config.packageId);
    console.log("\n==== Creating a character ====");
    console.log("Game Character ID:", GAME_CHARACTER_ID);
    console.log("Tribe ID:", TRIBE_ID);

    // Pre-compute the character ID before creation
    const precomputedCharacterId = deriveObjectId(
        config.objectRegistry,
        GAME_CHARACTER_ID,
        config.packageId
    );
    console.log("Pre-computed Character ID:", precomputedCharacterId);

    const tx = new Transaction();
    const [character] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::create_character`,
        arguments: [
            tx.object(config.objectRegistry),
            tx.object(adminCap!),
            tx.pure.u32(GAME_CHARACTER_ID),
            tx.pure.string(tenant),
            tx.pure.u32(TRIBE_ID),
            tx.pure.address(characterAddress),
            tx.pure.string("frontier-character-a"),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::share_character`,
        arguments: [character, tx.object(adminCap!)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true },
    });

    console.log(result);
    return precomputedCharacterId;
}

async function main() {
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.exportedKey);
        await createCharacter(env.tenant, env.playerAddress || "", ctx);
    } catch (error) {
        handleError(error);
    }
}

main().catch(console.error);
