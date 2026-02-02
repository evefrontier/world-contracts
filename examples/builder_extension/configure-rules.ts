import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { getEnvConfig, handleError, hydrateWorldConfig, initializeContext } from "../utils/helper";
import { resolveBuilderGateExtensionIds } from "../utils/builder-extension";

async function main() {
    console.log("============= Configure Builder Gate Rules ==============\n");

    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        const { client, keypair, address } = ctx;
        await hydrateWorldConfig(ctx);

        const { builderPackageId, adminCapId, gateRulesId } = resolveBuilderGateExtensionIds({
            adminAddressOwner: address,
        });

        const tx = new Transaction();
        tx.moveCall({
            target: `${builderPackageId}::gate::update_tribe_rules`,
            arguments: [tx.object(gateRulesId), tx.object(adminCapId), tx.pure.u32(100)],
        });

        const result = await client.signAndExecuteTransaction({
            transaction: tx,
            signer: keypair,
            options: { showEffects: true, showObjectChanges: true },
        });

        console.log("\nBuilder extension gate config updated!");
        console.log("Builder package:", builderPackageId);
        console.log("GateConfig:", gateRulesId);
        console.log("Transaction digest:", result.digest);
    } catch (error) {
        handleError(error);
    }
}

main().catch(console.error);
