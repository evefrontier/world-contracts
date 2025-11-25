export function hexToBytes(hexString: string): Uint8Array {
    const hex = hexString.startsWith("0x") ? hexString.slice(2) : hexString;
    const normalizedHex = hex.length % 2 === 0 ? hex : "0" + hex;

    const bytes = new Uint8Array(normalizedHex.length / 2);
    for (let i = 0; i < normalizedHex.length; i += 2) {
        bytes[i / 2] = parseInt(normalizedHex.substring(i, i + 2), 16);
    }
    return bytes;
}

export function toHex(bytes: Uint8Array): string {
    return (
        "0x" +
        Array.from(bytes)
            .map((b) => b.toString(16).padStart(2, "0"))
            .join("")
    );
}

export function fromHex(hex: string): Uint8Array {
    const cleanHex = hex.startsWith("0x") ? hex.slice(2) : hex;

    const bytes = new Uint8Array(cleanHex.length / 2);
    for (let i = 0; i < cleanHex.length; i += 2) {
        bytes[i / 2] = parseInt(cleanHex.slice(i, i + 2), 16);
    }

    return bytes;
}
