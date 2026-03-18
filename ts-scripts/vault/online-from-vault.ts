/**
 * Same as vault-borrow-online-return but signs with Character B (PLAYER_B_PRIVATE_KEY).
 * Use after vault-add-character-b: Character B (tribe member) borrows cap, onlines NWN, returns cap.
 *
 * Note: Fails with EFuelAlreadyBurning if the NWN is already online. Bring it offline first
 * (e.g. run offline-nwn as the cap owner, or after a previous borrow that onlined it).
 */
import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import { MODULE as extModule } from "../builder_extension/modules";
import { deriveObjectId } from "../utils/derive-object-id";
import { CLOCK_OBJECT_ID, NWN_ITEM_ID } from "../utils/constants";
import {
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
    requireEnv,
} from "../utils/helper";
import { getOwnerCap } from "../network-node/helper";
import { getBuilderPackageId, getVaultId } from "./helper";

async function main() {
    try {
        const env = getEnvConfig();
        const playerBKey = requireEnv("PLAYER_B_PRIVATE_KEY");
        const ctx = initializeContext(env.network, playerBKey);
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

        const { client, keypair, config } = ctx;
        const vaultId = getVaultId();
        const builderPackageId = getBuilderPackageId();

        const tx = new Transaction();
        const [ownerCap, receipt] = tx.moveCall({
            target: `${builderPackageId}::${extModule.VAULT}::borrow_owner_cap`,
            arguments: [tx.object(vaultId), tx.object(ownerCapId)],
        });
        tx.moveCall({
            target: `${config.packageId}::${MODULES.NETWORK_NODE}::online`,
            arguments: [tx.object(networkNodeObject), ownerCap, tx.object(CLOCK_OBJECT_ID)],
        });
        tx.moveCall({
            target: `${builderPackageId}::${extModule.VAULT}::return_owner_cap`,
            arguments: [tx.object(vaultId), ownerCap, receipt],
        });

        const result = await client.signAndExecuteTransaction({
            transaction: tx,
            signer: keypair,
            options: { showObjectChanges: true, showEffects: true },
        });
        console.log("Character B: borrowed, onlined NWN, returned cap. Digest:", result.digest);
    } catch (error) {
        handleError(error);
    }
}

main();
