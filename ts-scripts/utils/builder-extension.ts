import { findCreatedObjectId, readPublishOutputFile, requireId, typeName } from "./helper";
import { MODULE as extensionModule } from "../builder_extension/modules";

// Hardcoded publish output paths (relative to where you run the scripts from).
const BUILDER_PUBLISH_OUTPUT_PATH = "./deployments/testnet/builder_package.json";

// Optional manual overrides:
// If you don't have publish output JSON, you can hardcode these IDs here"";
const BUILDER_ADMIN_CAP_ID = "";
const BUILDER_EXTENSION_CONFIG_ID = "";

export type BuilderGateExtensionIds = {
    builderPackageId: string;
    adminCapId: string;
    extensionConfigId: string;
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
}): BuilderGateExtensionIds {
    const builderPackageId = requireBuilderPackageId();

    if (BUILDER_ADMIN_CAP_ID && BUILDER_EXTENSION_CONFIG_ID) {
        return {
            builderPackageId,
            adminCapId: BUILDER_ADMIN_CAP_ID,
            extensionConfigId: BUILDER_EXTENSION_CONFIG_ID,
        };
    }

    const { objectChanges } = readPublishOutputFile(BUILDER_PUBLISH_OUTPUT_PATH);

    const adminCapId = requireId(
        `Builder AdminCap (owner ${opts.adminAddressOwner})`,
        findCreatedObjectId(
            objectChanges,
            typeName(builderPackageId, extensionModule.CONFIG, "AdminCap"),
            {
                addressOwner: opts.adminAddressOwner,
            }
        )
    );

    const extensionConfigId = requireId(
        "Builder ExtensionConfig",
        findCreatedObjectId(
            objectChanges,
            typeName(builderPackageId, extensionModule.CONFIG, "ExtensionConfig")
        )
    );

    return { builderPackageId, adminCapId, extensionConfigId };
}
