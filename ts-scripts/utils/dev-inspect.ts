import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Transaction } from "@mysten/sui/transactions";
import { requireEnv } from "./helper";

function resolveDevInspectSender(senderAddress?: string): string {
    return senderAddress || requireEnv("ADMIN_ADDRESS") || "0x";
}

export async function devInspectMoveCallFirstReturnValueBytes(
    client: SuiJsonRpcClient,
    params: {
        target: string;
        typeArguments?: string[];
        senderAddress?: string;
        arguments: (tx: Transaction) => any[];
    }
): Promise<Uint8Array | null> {
    const tx = new Transaction();
    tx.moveCall({
        target: params.target,
        typeArguments: params.typeArguments,
        arguments: params.arguments(tx),
    });

    const result = await client.devInspectTransactionBlock({
        sender: resolveDevInspectSender(params.senderAddress),
        transactionBlock: tx,
    });

    if (result.effects?.status?.status !== "success") {
        return null;
    }

    const returnValues = result.results?.[0]?.returnValues;
    if (!returnValues?.length) return null;

    const [valueBytes] = returnValues[0];
    return Uint8Array.from(valueBytes);
}
