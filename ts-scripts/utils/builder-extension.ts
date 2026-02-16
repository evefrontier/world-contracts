import * as fs from "node:fs";
import {
    findCreatedObjectId,
    getDefaultBuilderPackageId,
    loadExtractedObjectIds,
    readPublishOutputFile,
    requireId,
    resolvePublishOutputPath,
    typeName,
} from "./helper";
import { MODULE as extensionModule } from "../builder_extension/modules";

function getBuilderPublishOutputPath(): string {
    const network = process.env.SUI_NETWORK ?? "localnet";
    return `./deployments/${network}/builder_package.json`;
}

export type BuilderGateExtensionIds = {
    builderPackageId: string;
    adminCapId: string;
    extensionConfigId: string;
};

export function requireBuilderPackageId(): string {
    const network = process.env.SUI_NETWORK ?? "localnet";
    const builderPackageId = getDefaultBuilderPackageId(network);
    if (!builderPackageId) {
        throw new Error("BUILDER_PACKAGE_ID is required. Set it in .env or run.");
    }
    return builderPackageId;
}

export function resolveBuilderGateExtensionIds(opts: {
    adminAddressOwner: string;
}): BuilderGateExtensionIds {
    const builderPackageId = requireBuilderPackageId();
    const network = process.env.SUI_NETWORK ?? "localnet";

    const extracted = loadExtractedObjectIds(network);
    const builder = extracted?.builder;
    const useExtracted =
        builder?.packageId === builderPackageId &&
        builder?.extensionConfigId &&
        builder?.adminCapId;

    if (useExtracted && builder?.adminCapId && builder?.extensionConfigId) {
        return {
            builderPackageId,
            adminCapId: builder.adminCapId,
            extensionConfigId: builder.extensionConfigId,
        };
    }

    const builderPath = getBuilderPublishOutputPath();
    const resolvedPath = resolvePublishOutputPath(builderPath);
    if (!fs.existsSync(resolvedPath)) {
        throw new Error(
            "Builder IDs not found. Run pnpm deploy-builder-ext then extract-object-ids."
        );
    }
    const { objectChanges } = readPublishOutputFile(resolvedPath);

    const extensionConfigId =
        extracted?.builder?.extensionConfigId ??
        requireId(
            "Builder ExtensionConfig",
            findCreatedObjectId(
                objectChanges,
                typeName(builderPackageId, extensionModule.CONFIG, "ExtensionConfig")
            )
        );

    const adminCapId = requireId(
        `Builder AdminCap (owner ${opts.adminAddressOwner})`,
        findCreatedObjectId(
            objectChanges,
            typeName(builderPackageId, extensionModule.CONFIG, "AdminCap"),
            { addressOwner: opts.adminAddressOwner }
        )
    );

    return { builderPackageId, adminCapId, extensionConfigId };
}
