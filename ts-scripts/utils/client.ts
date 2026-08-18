import { SuiGrpcClient } from "@mysten/sui/grpc";
import type { SuiClientTypes } from "@mysten/sui/client";
import { decodeSuiPrivateKey, type Signer } from "@mysten/sui/cryptography";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import type { Transaction } from "@mysten/sui/transactions";
import { getConfig, Network } from "./config";

export type SuiClient = SuiGrpcClient;
export type ExecutedTransaction = SuiClientTypes.Transaction<{
    effects: true;
    events: true;
}>;

export function createClient(network: Network = "localnet"): SuiClient {
    const config = getConfig(network);
    return new SuiGrpcClient({ network, baseUrl: config.url });
}

export function keypairFromPrivateKey(privateKey: string): Ed25519Keypair {
    const { scheme, secretKey } = decodeSuiPrivateKey(privateKey);
    if (scheme !== "ED25519") {
        throw new Error("Only ED25519 keys are supported");
    }
    return Ed25519Keypair.fromSecretKey(secretKey);
}

export function requireExecutedTx<Include extends SuiClientTypes.TransactionInclude>(
    result: SuiClientTypes.TransactionResult<Include>
): SuiClientTypes.Transaction<Include> {
    if (result.FailedTransaction) {
        const error = result.FailedTransaction.status.error;
        throw new Error(`Transaction failed: ${error?.message ?? "unknown error"}`);
    }
    return result.Transaction;
}

export async function signAndExecute(
    client: SuiClient,
    input: {
        transaction: Transaction;
        signer: Signer;
    }
): Promise<ExecutedTransaction> {
    const result = await client.signAndExecuteTransaction({
        transaction: input.transaction,
        signer: input.signer,
        include: { effects: true, events: true },
    });
    return requireExecutedTx(result);
}
