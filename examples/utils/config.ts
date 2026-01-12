// Configuration for different networks
export const NETWORKS = {
    localnet: {
        url: "http://127.0.0.1:9000",
        packageId: "0xf4ccb612f6332b0b83e93ce12fb2ada70722b3deb98fd2e0778ae8b1df6f011b",
        adminCapObjectId: "",
        characterRegisterId: "",
        serverAddressRegistry: "",
        assemblyRegistry: "",
        networkNodeRegistry: "",
        adminAclObjectId: "",
        energyConfig: "",
        fuelConfig: "",
    },
    testnet: {
        url: "https://fullnode.testnet.sui.io:443",
        packageId: "0x53f49f05b515e92d048415377a20d70744fb06fe45381366a2d39a1437cd6062",
        adminCapObjectId: "0xd3d95d2ea6ab719b1c0c73701bd8c3c93c735193cdfd40ccfe1768abcbb80233",
        characterRegisterId: "0x931aa7155a4f73b539875edccc17489a6f9f139113635dd92a901fa26bbf0758",
        serverAddressRegistry: "0x6d45c06ef804f37286e452dc60b9805b5f81251f320366ac7a7b02dbf66f2de0",
        assemblyRegistry: "0xe641630da0d3c581433e6788023372532a0b2f3455a50b2ee397eb47faa767cc",
        networkNodeRegistry: "0x97b0eacceeeb59076f218b8acc66d7773333c978569fd3943d3e4d83d11239c3",
        adminAclObjectId: "0x5b56045b4ec281637da79e9a25f72a59b749171680afa6523c0a61fc4cb89a2d",
        energyConfig: "0x7917cad413e8f3935cb367e610fd2415fc9d279cad6bab3090ec988b10b41bbb",
        fuelConfig: "0x0cc4b176c0bee0b02adc9faf2761bfec10d93fa3c67df5fce77ac7b73eb2deb5",
    },
    mainnet: {
        url: "https://fullnode.mainnet.sui.io:443",
        packageId: "0x...",
        adminCapObjectId: "",
        characterRegisterId: "",
        serverAddressRegistry: "",
        assemblyRegistry: "",
        networkNodeRegistry: "",
        adminAclObjectId: "",
        energyConfig: "",
        fuelConfig: "",
    },
};

export type Network = keyof typeof NETWORKS;

export function getConfig(network: Network = "localnet") {
    return NETWORKS[network];
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
