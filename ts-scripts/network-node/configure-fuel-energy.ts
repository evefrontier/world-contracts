import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES } from "../utils/config";
import {
    hydrateWorldConfig,
    initializeContext,
    handleError,
    getEnvConfig,
    getAdminCapId,
    parseBigIntArray,
} from "../utils/helper";
import { delay } from "../utils/delay";

async function setFuelEfficiency(
    fuelTypeId: bigint,
    fuelEfficiency: bigint,
    adminCap: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log(`\n==== Setting Fuel Efficiency ====`);
    console.log(
        `Fuel Type ID: ${fuelTypeId.toString()}, Efficiency: ${fuelEfficiency.toString()}%`
    );

    const tx = new Transaction();

    tx.moveCall({
        target: `${config.packageId}::${MODULES.FUEL}::set_fuel_efficiency`,
        arguments: [
            tx.object(config.fuelConfig),
            tx.object(adminCap),
            tx.pure.u64(fuelTypeId),
            tx.pure.u64(fuelEfficiency),
        ],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log("\n Fuel efficiency set successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function setEnergyConfig(
    assemblyTypeId: bigint,
    energyRequired: bigint,
    adminCap: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log(`\n==== Setting Energy Configuration ====`);
    console.log(
        `Assembly Type ID: ${assemblyTypeId.toString()}, Energy Required: ${energyRequired.toString()}`
    );

    const tx = new Transaction();
    tx.moveCall({
        target: `${config.packageId}::${MODULES.ENERGY}::set_energy_config`,
        arguments: [
            tx.object(config.energyConfig),
            tx.object(adminCap),
            tx.pure.u64(assemblyTypeId),
            tx.pure.u64(energyRequired),
        ],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log("\n Energy configuration set successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    console.log("============= Configure Fuel and Energy example ==============\n");

    try {
        const FUEL_TYPE_IDS = parseBigIntArray(process.env.FUEL_TYPE_IDS);
        const FUEL_EFFICIENCIES = parseBigIntArray(process.env.FUEL_EFFICIENCIES);
        const ASSEMBLY_TYPE_IDS = parseBigIntArray(process.env.ASSEMBLY_TYPE_IDS);
        const ENERGY_REQUIRED_VALUES = parseBigIntArray(process.env.ENERGY_REQUIRED_VALUES);

        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(ctx);
        const { client, keypair, config } = ctx;
        const adminCap = await getAdminCapId(client, config.packageId);
        if (!adminCap) throw new Error("AdminCap not found");

        // Configure fuel efficiencies
        if (FUEL_TYPE_IDS.length > 0 && FUEL_EFFICIENCIES.length > 0) {
            if (FUEL_TYPE_IDS.length !== FUEL_EFFICIENCIES.length) {
                throw new Error(
                    `FUEL_TYPE_IDS and FUEL_EFFICIENCIES arrays must have the same length. Got ${FUEL_TYPE_IDS.length} and ${FUEL_EFFICIENCIES.length}`
                );
            }

            for (let i = 0; i < FUEL_TYPE_IDS.length; i++) {
                await setFuelEfficiency(
                    FUEL_TYPE_IDS[i],
                    FUEL_EFFICIENCIES[i],
                    adminCap,
                    client,
                    keypair,
                    config
                );
                await delay(1000);
            }
        } else {
            console.log("\nNo fuel configurations provided. Skipping fuel efficiency setup.");
        }

        // Configure energy requirements
        if (ASSEMBLY_TYPE_IDS.length > 0 && ENERGY_REQUIRED_VALUES.length > 0) {
            if (ASSEMBLY_TYPE_IDS.length !== ENERGY_REQUIRED_VALUES.length) {
                throw new Error(
                    `ASSEMBLY_TYPE_IDS and ENERGY_REQUIRED_VALUES arrays must have the same length. Got ${ASSEMBLY_TYPE_IDS.length} and ${ENERGY_REQUIRED_VALUES.length}`
                );
            }

            for (let i = 0; i < ASSEMBLY_TYPE_IDS.length; i++) {
                await setEnergyConfig(
                    ASSEMBLY_TYPE_IDS[i],
                    ENERGY_REQUIRED_VALUES[i],
                    adminCap,
                    client,
                    keypair,
                    config
                );
                await delay(1000);
            }
        } else {
            console.log("\nNo energy configurations provided. Skipping energy setup.");
        }
    } catch (error) {
        handleError(error);
    }
}

main();
