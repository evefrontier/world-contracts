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
        packageId: "0x25ff0911b6fafe65e489acf1d02fbf4ca7eb64a6809f74c918b3fff1aa46b8ed",
        adminCap: "0x3d9e6b0906d17adc7f52ef7cb50df08360cde040010db6c11989ce10f7460808",
        serverAddressRegistry: "0xb225cbcb6165310b858372a161370f38f6c7f0964ba8af8aac37c1e83a7307f5",
        objectRegistry: "0xde3b269371e0b550c08e493f466a57a05455b2d65d8e39692bd0dd2304146f10",
        adminAcl: "0x3d0f198ab7fa3ac7e95af2bea322bbff9749c6070e52de907eae95048e3d5c80",
        energyConfig: "0xd2b10c3b3c24288a42cfcdb8bd7d5696ae64e6293c9ee08c2de52958a2542d76",
        fuelConfig: "0x879a85e0899a76d632055359a3e976d61317bf68db2dccd9c31c1ef414ed1873",
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
