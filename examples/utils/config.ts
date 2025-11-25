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
        packageId: "0xf4ccb612f6332b0b83e93ce12fb2ada70722b3deb98fd2e0778ae8b1df6f011b",
        adminCapObjectId: "0xe121f7c532a7e5c7be9372b25df22105790883c44daafa0dfb244af60eaec638",
        characterRegisterId: "0x8e09b2b046a5a933d6f3da9d1a08e6ae16d7486e0f78860ba138b57283dbfb1a",
        serverAddressRegistry: "0x62405cbcc9b0705c053648dcf0d89a8399f985d843970568c815bd05213e1101",
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
