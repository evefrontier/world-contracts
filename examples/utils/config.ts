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
        packageId: "0x033cc20195cc6a08a8a73635afd3d6550ca0416a782955c7d6ac035061cdd9a9",
        governorCap: "0x4fe68e8ac16354b4078d55ac7a5b71f16cd705a1da9bdfb42c11a8ef69c29fbc",
        serverAddressRegistry: "0x7a91579125dd960a2a414f7deb30b982f9b4d56d38ebb5d143c6f015d539eb3d",
        objectRegistry: "0xb54cebe05010536dcf05c5228f44241915bf075884ba6cb06b10a9a013a90b47",
        adminAcl: "0x3bcab26111f9db6c80b46803d0d081edafedcdaa55e8fb943bea73d505c92c26",
        energyConfig: "0xd372b98fb71a6a9cc266f5b34eed5f2078e8588fb0aa56921acbb79b90ed5296",
        fuelConfig: "0x7e7d7cf915f468df50c9cad9bf06c248ed5e3052fb739ddb7767f77847ef7830",
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
