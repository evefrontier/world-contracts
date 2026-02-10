export type WorldObjectIds = {
    governorCap: string;
    serverAddressRegistry: string;
    objectRegistry: string;
    adminAcl: string;
    energyConfig: string;
    fuelConfig: string;
    gateConfig: string;
};

/** Extracted object IDs written by extract-object-ids script (run once per deploy). */
export type ExtractedObjectIds = {
    network: string;
    world: WorldObjectIds & { packageId: string };
    builder?: {
        packageId: string;
        extensionConfigId: string;
        adminCapId?: string;
    };
};

export type WorldConfig = {
    url: string;
    packageId: string;
} & WorldObjectIds;

export type HydratedWorldConfig = WorldConfig;

export type Network = "localnet" | "testnet" | "devnet" | "mainnet";

export const DEFAULT_RPC_URLS: Record<Network, string> = {
    localnet: "http://127.0.0.1:9000",
    testnet: "https://fullnode.testnet.sui.io:443",
    devnet: "https://fullnode.devnet.sui.io:443",
    mainnet: "https://fullnode.mainnet.sui.io:443",
};

export function getConfig(network: Network = "localnet"): WorldConfig {
    const url = process.env.SUI_RPC_URL || DEFAULT_RPC_URLS[network];
    const packageId = process.env.WORLD_PACKAGE_ID || "";

    return {
        url,
        packageId,
        // Optional manual overrides:
        // If you don't have publish output JSON, you can hardcode these IDs here.
        governorCap: "",
        serverAddressRegistry: "",
        objectRegistry: "",
        adminAcl: "",
        energyConfig: "",
        fuelConfig: "",
        gateConfig: "",
    };
}

// Module names
export const MODULES = {
    WORLD: "world",
    ACCESS: "access",
    SIG_VERIFY: "sig_verify",
    LOCATION: "location",
    CHARACTER: "character",
    NETWORK_NODE: "network_node",
    ASSEMBLY: "assembly",
    STORAGE_UNIT: "storage_unit",
    GATE: "gate",
    FUEL: "fuel",
    ENERGY: "energy",
} as const;
