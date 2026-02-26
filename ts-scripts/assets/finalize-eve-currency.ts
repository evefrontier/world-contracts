/**
 * Finalize EVE currency registration in the CoinRegistry (0xc).
 * Run after publishing the assets package. The Currency<EVE> is already transferred
 * to the registry in init(); this tx promotes it to the shared derived object.
 *
 * Usage:
 *   EVE_CURRENCY_OBJECT_ID=0x... ASSETS_PACKAGE_ID=0x... npx tsx ts-scripts/assets/finalize-eve-currency.ts
 * Or set those in .env. Use the Currency<EVE> object ID (owner 0xc), not the Coin or other objects.
 */
import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { createClient, keypairFromPrivateKey } from "../utils/client";

const COIN_REGISTRY_ID = "0xc";

async function main() {
    const currencyObjectId = process.env.EVE_CURRENCY_OBJECT_ID;
    const packageId = process.env.ASSETS_PACKAGE_ID;

    if (!currencyObjectId || !packageId) {
        console.error(
            "SET the environment variables EVE_CURRENCY_OBJECT_ID and ASSETS_PACKAGE_ID."
        );
        process.exit(1);
    }

    const network = (process.env.SUI_NETWORK ?? "testnet") as
        | "localnet"
        | "testnet"
        | "devnet"
        | "mainnet";
    const client = createClient(network);
    const privateKey = process.env.GOVERNOR_PRIVATE_KEY;
    if (!privateKey) {
        console.error("Set GOVERNOR_PRIVATE_KEY in .env");
        process.exit(1);
    }
    const keypair = keypairFromPrivateKey(privateKey);
    const sender = keypair.getPublicKey().toSuiAddress();

    const coinType = `${packageId}::EVE::EVE`;

    const res = await client.getObject({ id: currencyObjectId });
    if (!res.data) {
        console.error("Currency object not found:", currencyObjectId, res.error ?? "");
        process.exit(1);
    }
    const { objectId, version, digest } = res.data;
    const currencyRef = { objectId, version, digest };

    const tx = new Transaction();
    tx.setSender(sender);
    tx.moveCall({
        target: "0x2::coin_registry::finalize_registration",
        typeArguments: [coinType],
        arguments: [tx.object(COIN_REGISTRY_ID), tx.receivingRef(currencyRef)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    if (result.effects?.status?.status === "success") {
        console.log("EVE currency finalized in CoinRegistry.");
        console.log("Digest:", result.digest);
    } else {
        console.error("Finalize failed:", result.effects?.status);
        process.exit(1);
    }
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
