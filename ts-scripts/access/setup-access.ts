import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES, Network } from "../utils/config";
import { delay } from "../utils/delay";
import { handleError, hydrateWorldConfig, initializeContext, requireEnv } from "../utils/helper";
import { signAndExecute } from "../utils/client";

function getAddresses(raw: string): string[] {
    return raw
        .split(",")
        .map((s) => s.trim().toLowerCase())
        .filter(Boolean);
}

function getAccessSetupEnv() {
    const network = (process.env.SUI_NETWORK as Network) || "testnet";
    // during development, we use the same private key for governor and admin
    const governorKey = process.env.GOVERNOR_PRIVATE_KEY || requireEnv("ADMIN_PRIVATE_KEY");
    const adminAddresses = getAddresses(requireEnv("ADMIN_ADDRESS"));
    const sponsorAddresses = getAddresses(requireEnv("SPONSOR_ADDRESSES"));

    return { network, governorKey, adminAddresses, sponsorAddresses };
}

async function setupAccess() {
    const { network, governorKey, adminAddresses, sponsorAddresses } = getAccessSetupEnv();
    const ctx = initializeContext(network, governorKey);
    const { client, keypair } = ctx;
    const config = await hydrateWorldConfig(ctx);

    const packageId = config.packageId;
    const governorCap = config.governorCap;
    const serverAddressRegistry = config.serverAddressRegistry;
    const adminAcl = config.adminAcl;

    if (!packageId || !governorCap || !serverAddressRegistry || !adminAcl) {
        throw new Error(`Config missing`);
    }

    if (adminAddresses.length === 0) {
        throw new Error("ADMIN_ADDRESS must contain at least one address");
    }
    if (sponsorAddresses.length === 0) {
        throw new Error("SPONSOR_ADDRESSES must contain at least one address");
    }

    const target = `${packageId}::${MODULES.ACCESS}`;

    console.log(`1. register_server_address (${adminAddresses.length} admins, atomic)...`);
    const tx1 = new Transaction();
    for (const adminAddress of adminAddresses) {
        tx1.moveCall({
            target: `${target}::register_server_address`,
            arguments: [
                tx1.object(serverAddressRegistry),
                tx1.object(governorCap),
                tx1.pure.address(adminAddress),
            ],
        });
    }
    const r1 = await signAndExecute(client, {
        signer: keypair,
        transaction: tx1,
    });
    console.log("   Digest:", r1.digest);
    await delay(5000);

    console.log(`2. add_sponsor_to_acl (${sponsorAddresses.length} sponsors, atomic)...`);
    const tx2 = new Transaction();
    for (const sponsorAddress of sponsorAddresses) {
        tx2.moveCall({
            target: `${target}::add_sponsor_to_acl`,
            arguments: [
                tx2.object(adminAcl),
                tx2.object(governorCap),
                tx2.pure.address(sponsorAddress),
            ],
        });
    }
    const r2 = await signAndExecute(client, {
        signer: keypair,
        transaction: tx2,
    });
    console.log("   Digest:", r2.digest);

    console.log("\n==== Access setup complete ====");
}

async function main() {
    try {
        await setupAccess();
    } catch (error) {
        handleError(error);
    }
}

main();
