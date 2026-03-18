/**
 * Remove an address from the vault's tribe members. Call as admin (AdminCap owner).
 */
import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULE as extModule } from "../builder_extension/modules";
import { getEnvConfig, handleError, hydrateWorldConfig, initializeContext } from "../utils/helper";
import { getBuilderPackageId, getVaultId, getAdminCapId } from "./helper";

async function main() {
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(ctx);

        const address = process.env.ADDRESS ?? process.argv[2];
        if (!address) throw new Error("Set ADDRESS in .env or pass as first arg");

        const adminCapId = getAdminCapId();
        const builderPackageId = getBuilderPackageId();
        const vaultId = getVaultId();

        const tx = new Transaction();
        tx.moveCall({
            target: `${builderPackageId}::${extModule.VAULT}::remove_tribe_member`,
            arguments: [tx.object(vaultId), tx.object(adminCapId), tx.pure.address(address)],
        });

        const result = await ctx.client.signAndExecuteTransaction({
            transaction: tx,
            signer: ctx.keypair,
            options: { showEffects: true },
        });
        console.log("Removed tribe member:", address, "Digest:", result.digest);
    } catch (error) {
        handleError(error);
    }
}

main();
