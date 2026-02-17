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

export const EXTRACTED_OBJECT_IDS_FILENAME = "extracted-object-ids.json";

const cache = new Map<string, Promise<WorldObjectIds>>();

export function getExtractedObjectIdsPath(network: string): string {
    return path.resolve(process.cwd(), "deployments", network, EXTRACTED_OBJECT_IDS_FILENAME);
}

function getWorldPublishOutputPath(network: string): string {
    const pathOverride = process.env.WORLD_PUBLISH_OUTPUT;
    if (pathOverride) return pathOverride;
    return `./deployments/${network}/world_package.json`;
}

export async function resolveWorldObjectIds(
    _client: SuiClient,
    worldPackageId: string,
    governorAddress: string,
    network?: string
): Promise<WorldObjectIds> {
    const net = network ?? process.env.SUI_NETWORK ?? "localnet";
    const worldPublishOutputPath = resolvePublishOutputPath(getWorldPublishOutputPath(net));
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
