/**
 * Borrow OwnerCap<NetworkNode> from character and transfer it to the vault's address.
 * Uses transfer_owner_cap_with_receipt so the return receipt is consumed (cap ends up in vault's receiving).
 *
 * Requires: VAULT_ID, WORLD_PACKAGE_ID, etc.
 */
import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
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
import { getVaultId } from "./helper";

async function depositOwnerCapToVault(
    networkNodeId: string,
    ownerCapId: string,
    ctx: ReturnType<typeof initializeContext>
) {
    const { client, keypair, config } = ctx;
    const characterId = deriveObjectId(config.objectRegistry, GAME_CHARACTER_ID, config.packageId);
    const vaultId = getVaultId();

    const tx = new Transaction();

    // 1. Borrow OwnerCap from character (returns cap + receipt; receipt must be consumed)
    const [ownerCap, receipt] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.NETWORK_NODE}::NetworkNode`],
        arguments: [tx.object(characterId), tx.object(ownerCapId)],
    });

    // 2. Transfer cap to vault's address (consumes receipt; cap ends up in vault's receiving)
    tx.moveCall({
        target: `${config.packageId}::${MODULES.ACCESS}::transfer_owner_cap_with_receipt`,
        typeArguments: [`${config.packageId}::${MODULES.NETWORK_NODE}::NetworkNode`],
        arguments: [ownerCap, receipt, tx.pure.address(vaultId)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log("OwnerCap deposited to vault. Digest:", result.digest);
    return result;
}

async function main() {
    try {
        const env = getEnvConfig();
        const playerKey = requireEnv("PLAYER_A_PRIVATE_KEY");
        const ctx = initializeContext(env.network, playerKey);
        await hydrateWorldConfig(ctx);

        const networkNodeObject = deriveObjectId(
            ctx.config.objectRegistry,
            NWN_ITEM_ID,
            ctx.config.packageId
        );
        const ownerCapId = await getOwnerCap(
            networkNodeObject,
            ctx.client,
            ctx.config,
            ctx.address
        );
        if (!ownerCapId) throw new Error(`OwnerCap not found for network node ${networkNodeObject}`);

        await depositOwnerCapToVault(networkNodeObject, ownerCapId, ctx);
    } catch (error) {
        handleError(error);
    }
}

main();
