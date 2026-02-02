import {
    findCreatedObjectId,
    readPublishOutputFile,
    requireId,
    resolvePublishOutputPath,
    typeName,
} from "./helper";

// Hardcoded publish output paths (relative to where you run the scripts from).
const BUILDER_PUBLISH_OUTPUT_PATH = "./deployments/testnet/builder_package.json";

export type BuilderGateExtensionIds = {
    builderPackageId: string;
    adminCapId: string;
    gateRulesId: string;
};

export function requireBuilderPackageId(): string {
    const builderPackageId = process.env.BUILDER_PACKAGE_ID;
    if (!builderPackageId) {
        throw new Error("BUILDER_PACKAGE_ID is required");
    }
    return builderPackageId;
}

export function resolveBuilderGateExtensionIds(opts: {
    adminAddressOwner: string;
    publishOutputPath?: string;
    builderPackageId?: string;
}): BuilderGateExtensionIds {
    const publishPath = resolvePublishOutputPath(
        opts.publishOutputPath ?? BUILDER_PUBLISH_OUTPUT_PATH
    );
    const { objectChanges } = readPublishOutputFile(publishPath);
    const builderPackageId = opts.builderPackageId ?? requireBuilderPackageId();

    const adminCapId = requireId(
        `Builder AdminCap (owner ${opts.adminAddressOwner})`,
        findCreatedObjectId(objectChanges, typeName(builderPackageId, "gate", "AdminCap"), {
            addressOwner: opts.adminAddressOwner,
        })
    );

    const gateRulesId = requireId(
        "Builder GateRules",
        findCreatedObjectId(objectChanges, typeName(builderPackageId, "gate", "GateRules"))
    );

    return { builderPackageId, adminCapId, gateRulesId };
}
