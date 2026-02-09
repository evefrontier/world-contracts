import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES, Network } from "../utils/config";
import { handleError, hydrateWorldConfig, initializeContext, requireEnv } from "../utils/helper";

function sleep(ms: number) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

function getAccessSetupEnv() {
    const network = (process.env.SUI_NETWORK as Network) || "testnet";
    const governorKey = requireEnv("GOVERNOR_PRIVATE_KEY");
    const adminAddress = requireEnv("ADMIN_ADDRESS");
    const sponsorAddress = requireEnv("SPONSOR_ADDRESS");

    return { network, governorKey, adminAddress, sponsorAddress };
}

async function setupAccess() {
    const { network, governorKey, adminAddress, sponsorAddress } = getAccessSetupEnv();
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

    const target = `${packageId}::${MODULES.ACCESS}`;

    console.log("1. create_admin_cap...");
    const tx1 = new Transaction();
    tx1.moveCall({
        target: `${target}::create_admin_cap`,
        arguments: [tx1.object(governorCap), tx1.pure.address(adminAddress)],
    });
    const r1 = await client.signAndExecuteTransaction({
        signer: keypair,
        transaction: tx1,
        options: { showObjectChanges: true },
    });
    console.log("   Digest:", r1.digest);
    if (r1.effects?.status?.status === "failure") {
        throw new Error(`create_admin_cap failed: ${JSON.stringify(r1.effects.status)}`);
    }
    await sleep(5000);

    console.log("2. register_server_address...");
    const tx2 = new Transaction();
    tx2.moveCall({
        target: `${target}::register_server_address`,
        arguments: [
            tx2.object(serverAddressRegistry),
            tx2.object(governorCap),
            tx2.pure.address(adminAddress),
        ],
    });
    const r2 = await client.signAndExecuteTransaction({
        signer: keypair,
        transaction: tx2,
        options: { showObjectChanges: true },
    });
    console.log("   Digest:", r2.digest);
    if (r2.effects?.status?.status === "failure") {
        throw new Error(`register_server_address failed: ${JSON.stringify(r2.effects.status)}`);
    }
    await sleep(5000);

    console.log("3. add_sponsor_to_acl...");
    const tx3 = new Transaction();
    tx3.moveCall({
        target: `${target}::add_sponsor_to_acl`,
        arguments: [
            tx3.object(adminAcl),
            tx3.object(governorCap),
            tx3.pure.address(sponsorAddress),
        ],
    });
    const r3 = await client.signAndExecuteTransaction({
        signer: keypair,
        transaction: tx3,
        options: { showObjectChanges: true },
    });
    console.log("   Digest:", r3.digest);
    if (r3.effects?.status?.status === "failure") {
        throw new Error(`add_sponsor_to_acl failed: ${JSON.stringify(r3.effects.status)}`);
    }
    await sleep(5000);

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
