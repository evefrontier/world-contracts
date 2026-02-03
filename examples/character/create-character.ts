import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import {
    hydrateWorldConfig,
    initializeContext,
    handleError,
    getEnvConfig,
    getAdminCapId,
    requireEnv,
} from "../utils/helper";
import { keypairFromPrivateKey } from "../utils/client";
import { MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import { GAME_CHARACTER_B_ID, GAME_CHARACTER_ID } from "../utils/constants";

const TRIBE_ID = 100;

async function createCharacter(
    tenant: string,
    characterAddress: string,
    gameCharacterId: number,
    ctx: ReturnType<typeof initializeContext>
): Promise<string> {
    const { client, keypair, config } = ctx;
    const adminCap = await getAdminCapId(client, config.packageId);
    if (!adminCap) throw new Error("AdminCap not found )");
    console.log("\n==== Creating a character ====");
    console.log("Game Character ID:", gameCharacterId);
    console.log("Tribe ID:", TRIBE_ID);

    // Pre-compute the character ID before creation
    const precomputedCharacterId = deriveObjectId(
        config.objectRegistry,
        gameCharacterId,
        config.packageId
    );
    console.log("Pre-computed Character ID:", precomputedCharacterId);

    const tx = new Transaction();
    const [character] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::create_character`,
        arguments: [
            tx.object(config.objectRegistry),
            tx.object(adminCap),
            tx.pure.u32(gameCharacterId),
            tx.pure.string(tenant),
            tx.pure.u32(TRIBE_ID),
            tx.pure.address(characterAddress),
            tx.pure.string("frontier-character-a"),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::share_character`,
        arguments: [character, tx.object(adminCap)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true },
    });

    console.log("Transaction digest:", result.digest);
    return precomputedCharacterId;
}

async function main() {
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(ctx);

        const playerKey = requireEnv("PLAYER_B_PRIVATE_KEY");
        const playerKeyA = requireEnv("PLAYER_A_PRIVATE_KEY");
        const playerAddressB = keypairFromPrivateKey(playerKey).getPublicKey().toSuiAddress();
        const playerAddressA = keypairFromPrivateKey(playerKeyA).getPublicKey().toSuiAddress();

        await createCharacter(env.tenant, playerAddressA, GAME_CHARACTER_ID, ctx);
        await createCharacter(env.tenant, playerAddressB, GAME_CHARACTER_B_ID, ctx);
    } catch (error) {
        handleError(error);
    }
}

main();
