import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { getConfig, Network } from "./config";

export function createClient(network: Network = "localnet"): SuiJsonRpcClient {
    const config = getConfig(network);
    return new SuiJsonRpcClient({ url: config.url, network });
}

export function keypairFromPrivateKey(privateKey: string): Ed25519Keypair {
    const { scheme, secretKey } = decodeSuiPrivateKey(privateKey);
    if (scheme !== "ED25519") {
        throw new Error("Only ED25519 keys are supported");
    }
    return Ed25519Keypair.fromSecretKey(secretKey);
}
