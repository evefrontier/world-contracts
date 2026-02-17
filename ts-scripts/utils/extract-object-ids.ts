/**
 * Extract world (and optional builder) object IDs from publish output JSON files
 * and write them to deployments/<network>/world-object-ids.json.
 * Run once after deploying world (and optionally builder extension).
 */
import "dotenv/config";
import * as fs from "node:fs";
import * as path from "node:path";
import { MODULES } from "./config";
import type { ExtractedObjectIds, WorldObjectIds } from "./config";
import {
    readPublishOutputFile,
    getPublishedPackageId,
    findCreatedObjectId,
    requireId,
    typeName,
    resolvePublishOutputPath,
} from "./helper";
import { keypairFromPrivateKey } from "./client";
import { MODULE as extensionModule } from "../builder_extension/modules";
import { getExtractedObjectIdsPath } from "./world-object-ids";

const DEFAULT_NETWORK = "localnet";

function getGovernorAddress(): string {
    const governorPrivateKey = process.env.GOVERNOR_PRIVATE_KEY || process.env.ADMIN_PRIVATE_KEY;
    if (governorPrivateKey) {
        return keypairFromPrivateKey(governorPrivateKey).getPublicKey().toSuiAddress();
    }
    const adminAddress = process.env.ADMIN_ADDRESS;
    if (adminAddress) return adminAddress;
    throw new Error("Set GOVERNOR_PRIVATE_KEY or ADMIN_ADDRESS to extract GovernorCap owner");
}

function extractWorldIds(
    worldPath: string,
    governorAddress: string
): WorldObjectIds & { packageId: string } {
    const resolved = resolvePublishOutputPath(worldPath);
    if (!fs.existsSync(resolved)) {
        throw new Error(`World publish output not found: ${resolved}`);
    }
    const { objectChanges } = readPublishOutputFile(resolved);
    const packageId = getPublishedPackageId(objectChanges);

    return {
        packageId,
        governorCap: requireId(
            `GovernorCap (owner ${governorAddress})`,
            findCreatedObjectId(objectChanges, typeName(packageId, MODULES.WORLD, "GovernorCap"), {
                addressOwner: governorAddress,
            })
        ),
        serverAddressRegistry: requireId(
            "ServerAddressRegistry",
            findCreatedObjectId(
                objectChanges,
                typeName(packageId, MODULES.ACCESS, "ServerAddressRegistry")
            )
        ),
        adminAcl: requireId(
            "AdminACL",
            findCreatedObjectId(objectChanges, typeName(packageId, MODULES.ACCESS, "AdminACL"))
        ),
        objectRegistry: requireId(
            "ObjectRegistry",
            findCreatedObjectId(
                objectChanges,
                typeName(packageId, "object_registry", "ObjectRegistry")
            )
        ),
        energyConfig: requireId(
            "EnergyConfig",
            findCreatedObjectId(objectChanges, typeName(packageId, MODULES.ENERGY, "EnergyConfig"))
        ),
        fuelConfig: requireId(
            "FuelConfig",
            findCreatedObjectId(objectChanges, typeName(packageId, MODULES.FUEL, "FuelConfig"))
        ),
        gateConfig: requireId(
            "GateConfig",
            findCreatedObjectId(objectChanges, typeName(packageId, MODULES.GATE, "GateConfig"))
        ),
    };
}

function extractBuilderIds(
    builderPath: string,
    adminAddress: string
): ExtractedObjectIds["builder"] {
    const resolved = resolvePublishOutputPath(builderPath);
    if (!fs.existsSync(resolved)) return undefined;

    const { objectChanges } = readPublishOutputFile(resolved);
    const builderPackageId = getPublishedPackageId(objectChanges);

    const adminCapId = findCreatedObjectId(
        objectChanges,
        typeName(builderPackageId, extensionModule.CONFIG, "AdminCap"),
        { addressOwner: adminAddress }
    );
    const extensionConfigId = findCreatedObjectId(
        objectChanges,
        typeName(builderPackageId, extensionModule.CONFIG, "ExtensionConfig")
    );
    if (!extensionConfigId) return undefined;

    return {
        packageId: builderPackageId,
        extensionConfigId,
        adminCapId: adminCapId ?? undefined,
    };
}

function main() {
    const network = process.env.SUI_NETWORK ?? DEFAULT_NETWORK;
    const worldPath =
        process.env.WORLD_PUBLISH_OUTPUT ?? `./deployments/${network}/world_package.json`;
    const builderPath =
        process.env.BUILDER_PUBLISH_OUTPUT ?? `./deployments/${network}/builder_package.json`;
    const outPath = getExtractedObjectIdsPath(network);

    const governorAddress = getGovernorAddress();

    const world = extractWorldIds(worldPath, governorAddress);
    const builder = extractBuilderIds(builderPath, governorAddress);

    const output: ExtractedObjectIds = { network, world, builder };

    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, JSON.stringify(output, null, 2), "utf8");
    console.log(`Wrote ${outPath}`);
}

main();
