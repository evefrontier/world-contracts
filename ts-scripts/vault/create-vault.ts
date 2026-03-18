/**
 * Create and share the NodeOwnerCapVault. Call once per env by an admin (AdminCap owner).
 * Set VAULT_ID from the created object id in the tx result.
 */
import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULE as extModule } from "../builder_extension/modules";
import { getEnvConfig, handleError, hydrateWorldConfig, initializeContext } from "../utils/helper";
import { getBuilderPackageId, getAdminCapId } from "./helper";

async function main() {
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(ctx);

        const adminCapId = getAdminCapId();
        const builderPackageId = getBuilderPackageId();

        const tx = new Transaction();
        tx.moveCall({
            target: `${builderPackageId}::${extModule.VAULT}::create_vault`,
            arguments: [tx.object(adminCapId)],
        });

        const result = await ctx.client.signAndExecuteTransaction({
            transaction: tx,
            signer: ctx.keypair,
            options: { showObjectChanges: true, showEffects: true },
        });

        const created = result.objectChanges?.find(
            (c: { type?: string; objectType?: string }) =>
                c?.type === "created" &&
                c?.objectType?.includes("NodeOwnerCapVault")
        ) as { objectId?: string } | undefined;
        const vaultId = created?.objectId;
        if (vaultId) {
            console.log("Vault created. Set in .env:");
            console.log(`VAULT_ID=${vaultId}`);
        }
        console.log("Digest:", result.digest);
    } catch (error) {
        handleError(error);
    }
}

main();
