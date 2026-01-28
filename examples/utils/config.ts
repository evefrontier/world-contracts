// Configuration for different networks
export const NETWORKS = {
    localnet: {
        url: "http://127.0.0.1:9000",
        packageId: "0xf4ccb612f6332b0b83e93ce12fb2ada70722b3deb98fd2e0778ae8b1df6f011b",
        adminCap: "",
        serverAddressRegistry: "",
        objectRegistry: "",
        adminAcl: "",
        energyConfig: "",
        fuelConfig: "",
    },
    testnet: {
        url: "https://fullnode.testnet.sui.io:443",
        packageId: "0x86fc8b0b12d3fc926c6ed82ed4b06c34ed71ad7b32e7c9779aad0e7e30c7b2a8",
        adminCap: "0x9c220cd9cc5e118a2d18f04a79290a86aa7904348d072d9dc5625ac7b2cca355",
        serverAddressRegistry: "0x58ad86486bf62e13b85f4cabeb2dc9a6b551cec784b489eb0a38581bfbeb2dba",
        objectRegistry: "0x31f4e6f1ec082e16ca4e00a20e3d5568d7ed8c908c3ea3b5b44e64c1718120b4",
        adminAcl: "0xe910a9b43837b373304572c928a84c39580477b185c64efec7abdd2b8bebc288",
        energyConfig: "0xf769a9d876012af6d6bdfd2f5996e34853e7888bc885424cf17e189bde08b23f",
        fuelConfig: "0x576121f552bd60d13cca37a5e3c2ab4cc56f633eda0d03007216201a0fa92fce",
    },
    mainnet: {
        url: "https://fullnode.mainnet.sui.io:443",
        packageId: "",
        adminCap: "",
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
