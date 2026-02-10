import path from "node:path";
import { SuiClient } from "@mysten/sui/client";
import { MODULES, WorldObjectIds } from "./config";
import {
    resolvePublishOutputPath,
    readPublishOutputFile,
    getPublishedPackageId,
    findCreatedObjectId,
    requireId,
    typeName,
} from "./helper";

// Hardcoded publish output paths (relative to where you run the scripts from).
const WORLD_PUBLISH_OUTPUT_PATH = "./deployments/testnet/world_package.json";
export const EXTRACTED_OBJECT_IDS_FILENAME = "extracted-object-ids.json";

const cache = new Map<string, Promise<WorldObjectIds>>();

export function getExtractedObjectIdsPath(network: string): string {
    return path.resolve(process.cwd(), "deployments", network, EXTRACTED_OBJECT_IDS_FILENAME);
}

export async function resolveWorldObjectIds(
    _client: SuiClient,
    worldPackageId: string,
    governorAddress: string
): Promise<WorldObjectIds> {
    const worldPublishOutputPath = resolvePublishOutputPath(WORLD_PUBLISH_OUTPUT_PATH);
    const { objectChanges: worldObjectChanges } = readPublishOutputFile(worldPublishOutputPath);
    const publishedWorldPackageId = getPublishedPackageId(worldObjectChanges);

    if (worldPackageId && publishedWorldPackageId !== worldPackageId) {
        throw new Error(
            [
                "WORLD_PACKAGE_ID does not match the publish output packageId.",
                `WORLD_PACKAGE_ID: ${worldPackageId}`,
                `publish output packageId: ${publishedWorldPackageId}`,
            ].join("\n")
        );
    }

    const key = `${publishedWorldPackageId}:${governorAddress}`;
    const cached = cache.get(key);
    if (cached) return await cached;

    const idsPromise = (async (): Promise<WorldObjectIds> => {
        const ids: WorldObjectIds = {
            governorCap: requireId(
                `GovernorCap (owner ${governorAddress})`,
                findCreatedObjectId(
                    worldObjectChanges,
                    typeName(publishedWorldPackageId, MODULES.WORLD, "GovernorCap"),
                    {
                        addressOwner: governorAddress,
                    }
                )
            ),
            serverAddressRegistry: requireId(
                "ServerAddressRegistry",
                findCreatedObjectId(
                    worldObjectChanges,
                    typeName(publishedWorldPackageId, MODULES.ACCESS, "ServerAddressRegistry")
                )
            ),
            adminAcl: requireId(
                "AdminACL",
                findCreatedObjectId(
                    worldObjectChanges,
                    typeName(publishedWorldPackageId, MODULES.ACCESS, "AdminACL")
                )
            ),
            objectRegistry: requireId(
                "ObjectRegistry",
                findCreatedObjectId(
                    worldObjectChanges,
                    typeName(publishedWorldPackageId, "object_registry", "ObjectRegistry")
                )
            ),
            energyConfig: requireId(
                "EnergyConfig",
                findCreatedObjectId(
                    worldObjectChanges,
                    typeName(publishedWorldPackageId, MODULES.ENERGY, "EnergyConfig")
                )
            ),
            fuelConfig: requireId(
                "FuelConfig",
                findCreatedObjectId(
                    worldObjectChanges,
                    typeName(publishedWorldPackageId, MODULES.FUEL, "FuelConfig")
                )
            ),
            gateConfig: requireId(
                "GateConfig",
                findCreatedObjectId(
                    worldObjectChanges,
                    typeName(publishedWorldPackageId, MODULES.GATE, "GateConfig")
                )
            ),
        };

        return ids;
    })();

    cache.set(key, idsPromise);
    return await idsPromise;
}
