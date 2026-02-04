// Configuration for different networks
export const NETWORKS = {
    localnet: {
        url: "http://127.0.0.1:9000",
        packageId: "0xf4ccb612f6332b0b83e93ce12fb2ada70722b3deb98fd2e0778ae8b1df6f011b",
        governorCap: "",
        serverAddressRegistry: "",
        objectRegistry: "",
        adminAcl: "",
        energyConfig: "",
        fuelConfig: "",
    },
    testnet: {
        url: "https://fullnode.testnet.sui.io:443",
        packageId: "0x285fbfa718dcbc0455c5447e9a28dc612ce35c72d66f642454c73f3db165a2bd",
        governorCap: "0x7e641626368f33fb4116f5fa980e16db41c456c21dada902f414a9828b237505",
        serverAddressRegistry: "0x6d3d9d693066110638bf11d1cc9d728075d3f18a4fae11c1401bc4354236097c",
        objectRegistry: "0xb7bab53f8e24109c24fa57b853c3d2b73b5559b7c4433e29d9f17207f2964a3f",
        adminAcl: "0x8d85a58f135441898080eff4bb3cc69ef1581f8351415b1fe76db7343f2f7f73",
        energyConfig: "0x7a23a982601de421a0f58dcf5790bca1933287afabbe25e13113430b4e491cbe",
        fuelConfig: "0xf14f5eec989c6990644fc839c50940cd20bff16a7a9c348b90a1de71c3e4767b",
    },
    mainnet: {
        url: "https://fullnode.mainnet.sui.io:443",
        packageId: "",
        governorCap: "",
        serverAddressRegistry: "",
        objectRegistry: "",
        adminAcl: "",
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
