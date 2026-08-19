import { Transaction } from "@mysten/sui/transactions";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { requireExecutedTx, type SuiClient } from "./client";

export async function executeSponsoredTransaction(
    tx: Transaction,
    client: SuiClient,
    playerKeypair: Ed25519Keypair,
    adminKeypair: Ed25519Keypair,
    playerAddress: string,
    adminAddress: string
) {
    const transactionKindBytes = await tx.build({ client, onlyTransactionKind: true });
    const gasCoins = await client.listCoins({
        owner: adminAddress,
        coinType: "0x2::sui::SUI",
        limit: 1,
    });

    if (gasCoins.objects.length === 0) {
        throw new Error("Admin has no gas coins to sponsor the transaction");
    }

    const gasPayment = gasCoins.objects.map((coin) => ({
        objectId: coin.objectId,
        version: coin.version,
        digest: coin.digest,
    }));

    const sponsoredTx = Transaction.fromKind(transactionKindBytes);
    sponsoredTx.setSender(playerAddress);
    sponsoredTx.setGasOwner(adminAddress);
    sponsoredTx.setGasPayment(gasPayment);
    const transactionBytes = await sponsoredTx.build({ client });

    const playerSignature = await playerKeypair.signTransaction(transactionBytes);
    const adminSignature = await adminKeypair.signTransaction(transactionBytes);

    return requireExecutedTx(
        await client.executeTransaction({
            transaction: transactionBytes,
            signatures: [playerSignature.signature, adminSignature.signature],
            include: { effects: true, events: true },
        })
    );
}
