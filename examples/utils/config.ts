// Configuration for different networks
export const NETWORKS = {
    localnet: {
        url: "http://127.0.0.1:9000",
        packageId: "0xf4ccb612f6332b0b83e93ce12fb2ada70722b3deb98fd2e0778ae8b1df6f011b",
        adminCapObjectId: "",
        characterRegisterId: "",
        serverAddressRegistry: "",
        assemblyRegistry: "",
        adminAclObjectId: "",
    },
    testnet: {
        url: "https://fullnode.testnet.sui.io:443",
        packageId: "0xc2756811d528e036189e011974a2fded87b2738a0a2fd301d263b0d9014a825f",
        adminCapObjectId: "0xbb68059059785e339301e46f5bd01eb4ff498617e08aa4e8ce40dcd700bedf6c",
        characterRegisterId: "0x648c0447a5acc1a5ba263264c0e674e3b73bb0e7ab5a94c06705b8b0bf9760c1",
        serverAddressRegistry: "0xe462e407b8479125b939357de767f3d0a149ea50c03f867f60b5c975f81b33ce",
        assemblyRegistry: "0xb142b80782fc818f89a941eeafd7d7bddac8beb322c5efe7151e2a09647004a6",
        adminAclObjectId: "0xba92c8a4085abf584d433fed140299a50dd682b5311b22beeac688441cd929f8",
    },
    mainnet: {
        url: "https://fullnode.mainnet.sui.io:443",
        packageId: "0x...",
        adminCapObjectId: "",
        characterRegisterId: "",
        serverAddressRegistry: "",
        assemblyRegistry: "",
        adminAclObjectId: "",
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
    ACCESS: "access",
    WORLD: "world",
} as const;
