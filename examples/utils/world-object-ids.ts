import { SuiClient } from "@mysten/sui/client";
import * as fs from "node:fs";
import * as path from "node:path";
import { MODULES, WorldObjectIds } from "./config";

// Hardcoded publish output paths (relative to where you run the scripts from).
const WORLD_PUBLISH_OUTPUT_PATH = "./deployments/testnet/world_package.json";

type PublishObjectChange = {
    type?: string;
    packageId?: string;
    objectType?: string;
    objectId?: string;
    owner?: { AddressOwner?: string } | unknown;
};

function readPublishOutputFile(
    filePath: string,
    labelForErrors: string
): { objectChanges: PublishObjectChange[] } {
    const raw = fs.readFileSync(filePath, "utf8");
    let parsed: { objectChanges?: unknown };
    try {
        parsed = JSON.parse(raw) as { objectChanges?: unknown };
    } catch {
        throw new Error(`Invalid JSON in ${labelForErrors}: ${filePath}`);
    }

    if (!Array.isArray(parsed.objectChanges)) {
        throw new Error(`Invalid publish output file (missing objectChanges[]): ${filePath}`);
    }

    return { objectChanges: parsed.objectChanges as PublishObjectChange[] };
}

function resolvePublishOutputPath(relativePath: string): string {
    return path.resolve(process.cwd(), relativePath);
}

function getPublishedPackageId(changes: PublishObjectChange[]): string {
    const published = changes.find((c) => c?.type === "published");
    if (typeof published?.packageId !== "string") {
        throw new Error("Publish output missing published packageId");
    }
    return published.packageId;
}

// TODO: use grpc query the object id instead of the publish output file
function findCreatedObjectId(
    changes: PublishObjectChange[],
    objectType: string,
    opts?: { addressOwner?: string }
): string | undefined {
    for (const c of changes) {
        if (c?.type !== "created") continue;
        if (c?.objectType !== objectType) continue;
        if (typeof c?.objectId !== "string") continue;

        if (opts?.addressOwner) {
            const owner = c.owner as any;
            if (owner?.AddressOwner !== opts.addressOwner) continue;
        }

        return c.objectId;
    }
}

function requireId(label: string, id: string | undefined): string {
    if (!id) throw new Error(`${label} not found`);
    return id;
}

function typeName(packageId: string, moduleName: string, structName: string): string {
    return `${packageId}::${moduleName}::${structName}`;
}

const cache = new Map<string, Promise<WorldObjectIds>>();

export async function resolveWorldObjectIds(
    _client: SuiClient,
    worldPackageId: string,
    governorAddress: string
): Promise<WorldObjectIds> {
    const worldPublishOutputPath = resolvePublishOutputPath(WORLD_PUBLISH_OUTPUT_PATH);
    const { objectChanges: worldObjectChanges } = readPublishOutputFile(
        worldPublishOutputPath,
        WORLD_PUBLISH_OUTPUT_PATH
    );
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
