import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import {
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
} from "../utils/helper";

async function addPackageToRegistry(
    registryId: string,
    adminAcl: string,
    newPackageId: string,
    ctx: ReturnType<typeof initializeContext>
) {
    const { client, keypair, config } = ctx;

    const tx = new Transaction();
    tx.moveCall({
        target: `${config.packageId}::package_registry::add_package_id`,
        arguments: [
            tx.object(registryId),
            tx.object(adminAcl),
            tx.pure.address(newPackageId),
        ],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEffects: true, showObjectChanges: true },
    });

    console.log("\nPackage ID added to registry!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    console.log("============= Add Package to Registry example ==============\n");

    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        const config = await hydrateWorldConfig(ctx);
        const { client } = ctx;

        const adminAcl = config.adminAcl;
        
        const registryId = config.packageRegistry;
        const newPackageId = process.env.NEW_PACKAGE_ID || config.packageId;

        if (!registryId) throw new Error("Registry ID not found in config");

        await addPackageToRegistry(
            registryId,
            adminAcl,
            newPackageId,
            ctx
        );
        
        // Let's read it back to prove it worked
        console.log("\nFetching registry from RPC...");
        const registryObj = await client.getObject({
            id: registryId,
            options: { showBcs: true, showContent: true }
        });
        
        console.log("Registry state:");
        console.dir(registryObj.data?.content, { depth: null });
        
    } catch (error) {
        handleError(error);
    }
}

main();
