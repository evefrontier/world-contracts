import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { getConfig, MODULES } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";
import { signPersonalMessage, toHex } from "./signMessage";

const FUNCTION_NAME = "verify_signature";

// Define the Message struct BCS schema
const Message = bcs.struct("Message", {
    from: bcs.Address,
    custom_message: bcs.vector(bcs.u8()),
    distance: bcs.u64(),
});

async function main() {
    console.log("Sui Personal Message Signing with Struct");

    const network = (process.env.SUI_NETWORK as any) || "localnet";
    const exportedKey = process.env.PRIVATE_KEY;
    if (!exportedKey) {
        throw new Error(
            "PRIVATE_KEY environment variable is required. Create a .env file with PRIVATE_KEY=suiprivkey1..."
        );
    }

    const client = createClient(network);
    const keypair = keypairFromPrivateKey(exportedKey);
    const config = getConfig(network);

    const address = keypair.getPublicKey().toSuiAddress();
    console.log("Signer address:", address);

    // Create the Message struct
    const message = {
        from: address,
        custom_message: Array.from(
            new TextEncoder().encode("I as a server attest this character is in this location")
        ),
        distance: 0n,
    };

    console.log("Message struct:", message);

    // Serialize the Message struct to bytes using BCS
    const messageBytes = Message.serialize(message).toBytes();
    console.log("Serialized message bytes:", messageBytes);
    console.log("Serialized message hex:", toHex(messageBytes));

    // Sign the serialized message
    const fullSignature = await signPersonalMessage(messageBytes, keypair);
    console.log("Full signature (97 bytes):", toHex(fullSignature));
    console.log("  - Flag (1 byte):", toHex(fullSignature.slice(0, 1)));
    console.log("  - Signature (64 bytes):", toHex(fullSignature.slice(1, 65)));
    console.log("  - Public key (32 bytes):", toHex(fullSignature.slice(65, 97)));

    console.log("Calling Smart Contract...");
    try {
        const tx = new Transaction();

        tx.moveCall({
            target: `${config.packageId}::${MODULES.SIG_VERIFY}::${FUNCTION_NAME}`,
            arguments: [
                tx.pure(bcs.vector(bcs.u8()).serialize(messageBytes)),
                tx.pure(bcs.vector(bcs.u8()).serialize(Array.from(fullSignature))),
                tx.pure.address(message.from),
            ],
        });

        const result = await client.devInspectTransactionBlock({
            transactionBlock: tx,
            sender: address,
        });

        console.log("====Verification result======");

        if (result.effects.status.status === "success") {
            const returnValues = result.results?.[0]?.returnValues;

            if (returnValues && returnValues.length > 0) {
                const verificationResult = returnValues[0][0][0];

                if (verificationResult === 1) {
                    console.log("Signature is VALID");
                } else {
                    console.log("Signature is INVALID (verification returned false)");
                }
            } else {
                console.log("Could not read return value");
            }
        } else {
            console.log("Transaction Failed");
            console.log("Error:", result.effects.status.error);
        }
    } catch (error) {
        console.log("Error during verification:", error);
    }
}

main().catch(console.error);
