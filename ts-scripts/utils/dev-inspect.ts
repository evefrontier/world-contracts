import { Transaction } from "@mysten/sui/transactions";
import type { SuiClient } from "./client";
import { requireEnv } from "./helper";

function resolveDevInspectSender(senderAddress?: string): string {
    return senderAddress || requireEnv("ADMIN_ADDRESS") || "0x";
}

export async function devInspectMoveCallFirstReturnValueBytes(
    client: SuiClient,
    params: {
        target: string;
        typeArguments?: string[];
        senderAddress?: string;
        arguments: (tx: Transaction) => any[];
    }
): Promise<Uint8Array | null> {
    const tx = new Transaction();
    tx.setSender(resolveDevInspectSender(params.senderAddress));
    tx.moveCall({
        target: params.target,
        typeArguments: params.typeArguments,
        arguments: params.arguments(tx),
    });

    const result = await client.simulateTransaction({
        transaction: tx,
        include: { commandResults: true, effects: true },
    });

    if (result.FailedTransaction) {
        return null;
    }

    return result.commandResults?.[0]?.returnValues?.[0]?.bcs ?? null;
}
