import { loadExtractedObjectIds, requireEnv } from "../utils/helper";

const VAULT_ID_ENV = "VAULT_ID";

const BUILDER_PACKAGE_ID = process.env.BUILDER_PACKAGE_ID ||
    "0xe3978d84324fe51a8ad1d313562dc063f0bf9cfba6ed69f6b530db67c27c396e" || "";

export function getBuilderPackageId(): string {
    return BUILDER_PACKAGE_ID;
}

export function getVaultId(): string {
    return requireEnv(VAULT_ID_ENV);
}

/** Hardcoded builder AdminCap (from extracted-object-ids testnet). Override with VAULT_ADMIN_CAP_ID in .env. */
const ADMIN_CAP_ID = process.env.ADMIN_CAP_ID ||
    "0x234f8e9b2c01815331828de7293791301883c1ce50a499f2b4b7128463d9351f";

export function getAdminCapId(): string {
    return ADMIN_CAP_ID;
}
