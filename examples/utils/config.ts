// Configuration for different networks
export const NETWORKS = {
    localnet: {
        url: "http://127.0.0.1:9000",
        packageId: "0xf4ccb612f6332b0b83e93ce12fb2ada70722b3deb98fd2e0778ae8b1df6f011b",
        adminCapObjectId: "",
        characterRegisterId: "",
        serverAddressRegistry: "",
    },
    testnet: {
        url: "https://fullnode.testnet.sui.io:443",
        packageId: "0x8941524ae368d91a7f9ee95466d3e60b75ddc16de3c3b9233dc11f85ce86c258",
        adminCapObjectId: "0x73361a1cbe38e33010363cd727b54fbca3a58c7ac95ca3b647a167c57f79f95f",
        characterRegisterId: "0x70c704eb8ee89c910a31ecf550a85514d5a4d3d2742cc2fbd5b2131c3513b79c",
        serverAddressRegistry: "0xc259666e108ef25275566f3a2e4843ae113f86d42d89e1e31f752426c99c9e7d",
    },
    mainnet: {
        url: "https://fullnode.mainnet.sui.io:443",
        packageId: "0x...",
        adminCapObjectId: "",
        characterRegisterId: "",
        serverAddressRegistry: "",
    },
};

export type Network = keyof typeof NETWORKS;

export function getConfig(network: Network = "localnet") {
    return NETWORKS[network];
}

// Module names
export const MODULES = {
    SIG_VERIFY: "sig_verify",
    LOCATION: "location",
    GATE: "gate",
    STORAGE_UNIT: "storage_unit",
    CHARACTER: "character",
    AUTHORITY: "authority",
    WORLD: "world",
} as const;
