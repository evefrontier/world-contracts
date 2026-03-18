/**
 * Withdraw OwnerCap<NetworkNode> from the shared vault and transfer it to the character's address.
 * The character can then receive it via character::borrow_owner_cap (Receiving ticket).
 *
 * Requires: VAULT_ID, BUILDER_PACKAGE_ID. Need owner_cap_id to withdraw.
 */
import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULE as extModule } from "../builder_extension/modules";
import { deriveObjectId } from "../utils/derive-object-id";
import { GAME_CHARACTER_ID, NWN_ITEM_ID } from "../utils/constants";
import {
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
    requireEnv,
} from "../utils/helper";
import { getOwnerCap } from "../network-node/helper";
import { getBuilderPackageId, getVaultId } from "./helper";
import { keypairFromPrivateKey } from "../utils/client";

async function withdrawOwnerCapToCharacter(
    ownerCapId: string,
    characterId: string,
    ctx: ReturnType<typeof initializeContext>
) {
    const { client, keypair } = ctx;
    const vaultId = getVaultId();
    const builderPackageId = getBuilderPackageId();

    const tx = new Transaction();
    tx.moveCall({
        target: `${builderPackageId}::${extModule.VAULT}::return_owner_cap_to_character`,
        arguments: [
            tx.object(vaultId),
            tx.object(ownerCapId), // Receiving ticket: ref to OwnerCap in vault
            tx.object(characterId),
        ],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log("OwnerCap withdrawn to character address. Digest:", result.digest);
    return result;
}

async function main() {
    try {
        const env = getEnvConfig();
        const playerKey = requireEnv("PLAYER_B_PRIVATE_KEY");

        const ctx = initializeContext(env.network, playerKey);
        await hydrateWorldConfig(ctx);

        const networkNodeObject = deriveObjectId(
            ctx.config.objectRegistry,
            NWN_ITEM_ID,
            ctx.config.packageId
        );
        const characterId = deriveObjectId(ctx.config.objectRegistry, GAME_CHARACTER_ID, ctx.config.packageId);

        const ownerCapId = await getOwnerCap(
            networkNodeObject,
            ctx.client,
            ctx.config,
            ctx.address
        );
        if (!ownerCapId) throw new Error(`OwnerCap not found for network node ${networkNodeObject}`);

        await withdrawOwnerCapToCharacter(ownerCapId, characterId, ctx);
    } catch (error) {
        handleError(error);
    }
}

main();
