/**
 * Finalize EVE currency registration in the CoinRegistry (0xc).
 * Run after publishing the assets package. The Currency<EVE> is already transferred
 * to the registry in init(); this tx promotes it to the shared derived object.
 *
 * Usage:
 *   EVE_CURRENCY_OBJECT_ID=0x... ASSETS_PACKAGE_ID=0x... npx tsx ts-scripts/assets/finalize-eve-currency.ts
 * Or set those in .env / rely on deployments/<network>/extracted-object-ids.json after extract-object-ids.
 */
import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { createClient, keypairFromPrivateKey, signAndExecute } from "../utils/client";
import { loadExtractedObjectIds } from "../utils/helper";
import type { Network } from "../utils/config";

const COIN_REGISTRY_ID = "0xc";

async function main() {
    const network = (process.env.SUI_NETWORK ?? "localnet") as Network;
    const extracted = loadExtractedObjectIds(network);

    const currencyObjectId = process.env.EVE_CURRENCY_OBJECT_ID || extracted?.assets?.currencyId;
    const packageId = process.env.ASSETS_PACKAGE_ID || extracted?.assets?.packageId;

    if (!currencyObjectId || !packageId) {
        console.error(
            "Set EVE_CURRENCY_OBJECT_ID and ASSETS_PACKAGE_ID, or run extract-object-ids after deploying assets."
        );
        process.exit(1);
    }

    const client = createClient(network);
    const privateKey = process.env.GOVERNOR_PRIVATE_KEY;
    if (!privateKey) {
        console.error("Set GOVERNOR_PRIVATE_KEY in .env");
        process.exit(1);
    }
    const keypair = keypairFromPrivateKey(privateKey);
    const sender = keypair.getPublicKey().toSuiAddress();

    const coinType = `${packageId}::EVE::EVE`;

    const { object } = await client.getObject({ objectId: currencyObjectId });
    const currencyRef = {
        objectId: object.objectId,
        version: object.version,
        digest: object.digest,
    };

    const tx = new Transaction();
    tx.setSender(sender);
    tx.moveCall({
        target: "0x2::coin_registry::finalize_registration",
        typeArguments: [coinType],
        arguments: [tx.object(COIN_REGISTRY_ID), tx.receivingRef(currencyRef)],
    });

    const result = await signAndExecute(client, {
        transaction: tx,
        signer: keypair,
    });

    console.log("EVE currency finalized in CoinRegistry.");
    console.log("Digest:", result.digest);
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
