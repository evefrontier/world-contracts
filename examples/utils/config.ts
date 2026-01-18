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
        packageId: "0x6d263638f3c31f3fd6c429649f2d5578433bae9db62867cd49a20427d763648d",
        adminCap: "0x909bd6e26877d6efd9c94681879c78e84aa7ba6a996343ca245faec0e63f7c98",
        serverAddressRegistry: "0x432b767dbd6885634a3b36803a98d9ba7b7264d0f520608526f86035240b2212",
        objectRegistry: "0xe1961afc3988c313a80f9fe29413685a24096bf2b54f401ad87f84681b642269",
        adminAcl: "0xe7beb2af10d1045de6bdeac5cda54e98153f90e7d0e8f9623bce4264386d66fe",
        energyConfig: "0x30bc692117b9287fdd8c90eeb6f218e47084455c661b408997afcb0896f319a5",
        fuelConfig: "0xc0a5f34fa3f581d709c89ad59233a66b4b63623e5ac75acdaca5a73c89041421",
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
