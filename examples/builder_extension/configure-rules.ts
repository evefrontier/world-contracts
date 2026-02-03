import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { getEnvConfig, handleError, hydrateWorldConfig, initializeContext } from "../utils/helper";
import { resolveBuilderGateExtensionIds } from "../utils/builder-extension";
import { ITEM_A_TYPE_ID } from "../utils/constants";
import { MODULE } from "./modules";

async function main() {
    console.log("============= Configure Builder Gate Rules ==============\n");

    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        const { client, keypair, address } = ctx;
        await hydrateWorldConfig(ctx);

        const { builderPackageId, adminCapId, extensionConfigId } = resolveBuilderGateExtensionIds({
            adminAddressOwner: address,
        });

        const tx = new Transaction();
        tx.moveCall({
            target: `${builderPackageId}::${MODULE.TRIBE_PERMIT}::set_tribe_config`,
            arguments: [tx.object(extensionConfigId), tx.object(adminCapId), tx.pure.u32(100)],
        });

        tx.moveCall({
            target: `${builderPackageId}::${MODULE.CORPSE_GATE_BOUNTY}::set_bounty_type_id`,
            arguments: [
                tx.object(extensionConfigId),
                tx.object(adminCapId),
                tx.pure.u64(ITEM_A_TYPE_ID),
            ],
        });

        const result = await client.signAndExecuteTransaction({
            transaction: tx,
            signer: keypair,
            options: { showEffects: true, showObjectChanges: true },
        });

        console.log("\nBuilder extension gate config updated!");
        console.log("Transaction digest:", result.digest);
    } catch (error) {
        handleError(error);
    }
}

main();
