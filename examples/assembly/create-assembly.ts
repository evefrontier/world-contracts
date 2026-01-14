import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";
import { hexToBytes } from "../utils/helper";
import {
    LOCATION_HASH,
    GAME_CHARACTER_ID,
    NWN_ITEM_ID,
    ASSEMBLY_TYPE_ID,
    ASSEMBLY_ITEM_ID,
} from "../utils/constants";
import { deriveObjectId } from "../utils/derive-object-id";

async function createAssembly(
    characterObjectId: string,
    networkNodeObjectId: string,
    typeId: bigint,
    itemId: bigint,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    const tx = new Transaction();

    const [assembly] = tx.moveCall({
        target: `${config.packageId}::${MODULES.ASSEMBLY}::anchor`,
        arguments: [
            tx.object(config.objectRegistry),
            tx.object(networkNodeObjectId),
            tx.object(characterObjectId),
            tx.object(config.adminCap),
            tx.pure.u64(itemId),
            tx.pure.u64(typeId),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(LOCATION_HASH))),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.ASSEMBLY}::share_assembly`,
        arguments: [assembly, tx.object(config.adminCap)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEvents: true },
    });

    console.log(result);

    const assemblyEvent = result.events?.find((event) =>
        event.type.endsWith("::assembly::AssemblyCreatedEvent")
    );

    if (!assemblyEvent?.parsedJson) {
        throw new Error("AssemblyCreatedEvent not found in transaction result");
    }

    const assemblyId = (assemblyEvent.parsedJson as { assembly_id: string }).assembly_id;
    console.log("Assembly Object Id: ", assemblyId);

    const ownerCapObjectId = (assemblyEvent.parsedJson as { owner_cap_id: string }).owner_cap_id;
    console.log("OwnerCap Object Id: ", ownerCapObjectId);
}

async function main() {
    try {
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PRIVATE_KEY;
        const playerExportedKey = process.env.PLAYER_A_PRIVATE_KEY || exportedKey;
        if (!exportedKey || !playerExportedKey) {
            throw new Error(
                "PRIVATE_KEY environment variable is required eg: PRIVATE_KEY=suiprivkey1..."
            );
        }

        const client = createClient(network);
        const keypair = keypairFromPrivateKey(exportedKey);
        const playerKeypair = keypairFromPrivateKey(playerExportedKey);
        const config = getConfig(network);

        const playerAddress = playerKeypair.getPublicKey().toSuiAddress();
        const adminAddress = keypair.getPublicKey().toSuiAddress();

        let characterObject = deriveObjectId(
            config.objectRegistry,
            GAME_CHARACTER_ID,
            config.packageId
        );
        let networkNodeObject = deriveObjectId(
            config.objectRegistry,
            NWN_ITEM_ID,
            config.packageId
        );

        await createAssembly(
            characterObject,
            networkNodeObject,
            ASSEMBLY_TYPE_ID,
            ASSEMBLY_ITEM_ID,
            client,
            keypair,
            config
        );
    } catch (error) {
        console.error("\n=== Error ===");
        console.error("Error:", error instanceof Error ? error.message : error);
        if (error instanceof Error && error.stack) {
            console.error("Stack:", error.stack);
        }
        process.exit(1);
    }
}

main().catch(console.error);
