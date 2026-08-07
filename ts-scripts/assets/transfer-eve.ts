/**
 * Transfer EVE from the deployer (GOVERNOR) to another address.
 *
 * Usage:
 *   RECIPIENT=0x... AMOUNT=100 npx tsx ts-scripts/assets/transfer-eve.ts
 * Or set in .env. AMOUNT is whole EVE tokens (9 decimals), e.g. 100 = 100 EVE.
 * ASSETS_PACKAGE_ID may come from deployments/<network>/extracted-object-ids.json.
 */
import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { Network } from "../utils/config";
import { initializeContext, loadExtractedObjectIds, requireEnv } from "../utils/helper";

const EVE_DECIMALS = 9;
const SCALE = 10n ** BigInt(EVE_DECIMALS);

async function main() {
    const network = (process.env.SUI_NETWORK as Network) ?? "localnet";
    const extracted = loadExtractedObjectIds(network);

    const packageId = process.env.ASSETS_PACKAGE_ID || extracted?.assets?.packageId;
    const recipient =
        process.env.RECIPIENT || process.env.ASSET_HOLDER || process.env.ADMIN_ADDRESS;
    const amountStr = process.env.AMOUNT ?? "1";

    if (!packageId || !recipient) {
        console.error(
            "Set ASSETS_PACKAGE_ID (or deploy assets + extract-object-ids) and RECIPIENT (or ADMIN_ADDRESS)."
        );
        process.exit(1);
    }

    let amountEve: bigint;
    try {
        if (!/^\d+$/.test(amountStr.trim())) {
            throw new Error("not an integer");
        }
        amountEve = BigInt(amountStr.trim());
    } catch {
        console.error("AMOUNT must be a positive whole number of EVE tokens.");
        process.exit(1);
    }
    if (amountEve <= 0n) {
        console.error("AMOUNT must be a positive whole number of EVE tokens.");
        process.exit(1);
    }

    const amountRaw = amountEve * SCALE;

    const {
        client,
        keypair,
        address: sender,
    } = initializeContext(network, requireEnv("GOVERNOR_PRIVATE_KEY"));

    const coinType = `${packageId}::EVE::EVE`;

    // Assume the deployer has a single EVE coin object.
    const coinsRes = await client.getCoins({
        owner: sender,
        coinType,
        limit: 1,
    });

    const coin = coinsRes.data[0];
    if (!coin) {
        console.error("Deployer has no EVE coins.");
        process.exit(1);
    }
    if (BigInt(coin.balance) < amountRaw) {
        console.error(
            `Insufficient balance. Have ${coin.balance} raw (~${BigInt(coin.balance) / SCALE} EVE), need ${amountRaw} raw (${amountEve} EVE).`
        );
        process.exit(1);
    }

    const tx = new Transaction();
    tx.setSender(sender);
    const [toSend] = tx.splitCoins(tx.object(coin.coinObjectId), [amountRaw]);
    tx.transferObjects([toSend], recipient);

    const result = await client.signAndExecuteTransaction({
        signer: keypair,
        transaction: tx,
        options: { showObjectChanges: true, showEffects: true },
    });

    if (result.effects?.status?.status === "success") {
        console.log(`Transferred ${amountEve} EVE to ${recipient}`);
        console.log("Digest:", result.digest);
    } else {
        console.error("Transfer failed:", result.effects?.status);
        process.exit(1);
    }
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
