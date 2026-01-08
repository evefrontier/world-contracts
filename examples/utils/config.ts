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
        packageId: "0xc3e0f81c9de104e9f773e495f53ac4175bc4fb5da81df7b7376623725515d1e5",
        adminCapObjectId: "0x4fe0c11a9f1e953b0b422e527fa2f30709e6086bd928be573bb7693ca75fcfe7",
        characterRegisterId: "0x0b901b8fba67e657d5957dcc08d95302b38ff1a02c51d7a4207107d063000086",
        serverAddressRegistry: "0x1387dd340a18eac4a9283ee1ba71dee90ce484e375e164dda0bf812f62ddfca3",
        assemblyRegistry: "0x5ae96e3c2a4e71db99f02c60b2272766609a99172bdf6c25ec1bbeeaebfc12f3",
        networkNodeRegistry: "0x355448aa8195c5a093f70016be7dfb4e3cdb16b0ac52cc17377255371f4d2e09",
        adminAclObjectId: "0x5241fe7ac573238083bcbc16de274086b83ee6b365493cb7a8cb618bee18cccb",
        energyConfig: "0xf39e4f6c8c674168d3a8407a3cd87db79399052bb88d718526a59c69545123aa",
        fuelConfig: "0x2cb9d5820aeb99aae7937c304deefa4e345bc2c77d459cd65b431d9de84291bb",
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
