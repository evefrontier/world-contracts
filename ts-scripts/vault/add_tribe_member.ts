/**
 * Add Character B's wallet as a vault tribe member (admin signs).
 * Use this to test: Character A deposits NWN OwnerCap → Character B (tribe member) can borrow/use/return or withdraw.
 *
 * Requires: PLAYER_B_PRIVATE_KEY in .env (used only to derive Character B's address).
 */
import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULE as extModule } from "../builder_extension/modules";
import {
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
    requireEnv,
} from "../utils/helper";
import { keypairFromPrivateKey } from "../utils/client";
import { getBuilderPackageId, getVaultId, getAdminCapId } from "./helper";

async function main() {
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(ctx);

        const playerBKey = requireEnv("PLAYER_B_PRIVATE_KEY");
        const characterBAddress = keypairFromPrivateKey(playerBKey).getPublicKey().toSuiAddress();

        const adminCapId = getAdminCapId();
        const builderPackageId = getBuilderPackageId();
        const vaultId = getVaultId();

        const tx = new Transaction();
        tx.moveCall({
            target: `${builderPackageId}::${extModule.VAULT}::add_tribe_member`,
            arguments: [
                tx.object(vaultId),
                tx.object(adminCapId),
                tx.pure.address(characterBAddress),
            ],
        });

        const result = await ctx.client.signAndExecuteTransaction({
            transaction: tx,
            signer: ctx.keypair,
            options: { showEffects: true },
        });
        console.log("Added Character B as tribe member:", characterBAddress, "Digest:", result.digest);
    } catch (error) {
        handleError(error);
    }
}

main();
