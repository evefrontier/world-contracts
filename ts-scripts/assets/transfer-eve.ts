/**
 * Transfer EVE from the deployer (GOVERNOR) to another address.
 *
 * Usage:
 *   RECIPIENT=0x... AMOUNT=100 npx tsx ts-scripts/assets/transfer-eve.ts
 * Or set in .env. AMOUNT is in EVE (9 decimals, e.g. 100 = 100 EVE).
 */
import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { Network } from "../utils/config";
import { initializeContext, requireEnv } from "../utils/helper";

const EVE_DECIMALS = 9;
const SCALE = 10n ** BigInt(EVE_DECIMALS);

async function main() {
    // use the .env or hardcode the values
    const packageId = process.env.ASSETS_PACKAGE_ID;
    const recipient = process.env.ASSET_HOLDER;
    const amountStr = Number(process.env.AMOUNT ?? 1);

    if (!packageId || !recipient || amountStr === undefined || amountStr <= 0) {
        console.error("Set ASSETS_PACKAGE_ID, RECIPIENT, and AMOUNT (EVE amount, e.g. 100).");
        process.exit(1);
    }

    const amountEve = Number(amountStr);
    if (!Number.isFinite(amountEve) || amountEve <= 0) {
        console.error("AMOUNT must be a positive number.");
        process.exit(1);
    }

    const amountRaw = BigInt(Math.floor(amountEve * Number(SCALE)));

    const network = (process.env.SUI_NETWORK as Network) ?? "testnet";
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
            `Insufficient balance. Have ${coin.balance} raw (~${Number(coin.balance) / Number(SCALE)} EVE), need ${amountRaw} raw (${amountEve} EVE).`
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
