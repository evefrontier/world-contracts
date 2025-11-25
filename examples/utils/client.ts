import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { getConfig, Network } from "./config";

export function createClient(network: Network = "localnet"): SuiClient {
    const config = getConfig(network);
    return new SuiClient({ url: config.url });
}

export function loadKeypair(privateKey: string): Ed25519Keypair {
    const { schema, secretKey } = decodeSuiPrivateKey(privateKey);
    if (schema !== "ED25519") {
        throw new Error("Only ED25519 keys are supported");
    }
    return Ed25519Keypair.fromSecretKey(secretKey);
}
