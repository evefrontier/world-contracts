/**
 * Validates that an abort code is in a valid format
 * A valid Move abort code should be a u64 (64 bits = 16 hex digits)
 */
export function isValidAbortCode(abortCode: string): boolean {
    if (!abortCode || abortCode.trim() === "") {
        return false;
    }

    // Check if it's a hex string
    if (abortCode.startsWith("0x") || abortCode.startsWith("0X")) {
        const hexPart = abortCode.slice(2);
        // Valid hex should be exactly 16 hex digits for a full u64 abort code
        // Move clever error codes are always full 64-bit values
        if (!/^[0-9a-fA-F]{16}$/.test(hexPart)) {
            return false;
        }
        // Check if it's a valid u64 (not exceeding 2^64 - 1)
        try {
            const value = BigInt(abortCode);
            return value >= 0n && value <= 0xffffffffffffffffn;
        } catch {
            return false;
        }
    } else {
        // Decimal format - should be a valid number
        if (!/^\d+$/.test(abortCode)) {
            return false;
        }
        try {
            const value = BigInt(abortCode);
            // Should be a valid u64 (0 to 2^64 - 1)
            return value >= 0n && value <= 0xffffffffffffffffn;
        } catch {
            return false;
        }
    }
}

/**
 * Decodes a Sui/Move clever error code (u64) into its fields.
 * Returns an object with version, error_code, line_number, identifier_index, constant_index.
 * @param abortCode - The abort code (decimal or hex string, or bigint).
 * @throws Error if the abort code format is invalid
 */
export function decodeCleverErrorCode(abortCode: string | number | bigint): {
    version: number;
    reserved: number;
    error_code: number;
    line_number: number;
    identifier_index: number;
    constant_index: number;
} {
    // Validate string format
    if (typeof abortCode === "string" && !isValidAbortCode(abortCode)) {
        throw new Error(
            `Invalid abort code format: "${abortCode}". ` +
                `Abort codes should be valid u64 values (8-16 hex digits for hex format, ` +
                `or valid decimal numbers).`
        );
    }

    // Convert to BigInt for bit operations
    let value: bigint;
    if (typeof abortCode === "bigint") {
        value = abortCode;
    } else if (typeof abortCode === "string") {
        // Handle hex strings (0x... or 0X...)
        if (abortCode.startsWith("0x") || abortCode.startsWith("0X")) {
            value = BigInt(abortCode);
        } else {
            value = BigInt(abortCode);
        }
    } else {
        value = BigInt(abortCode);
    }

    // Extract fields based on ErrorBitset layout:
    // | version: 4 bits | reserved: 4 bits | error_code: 8 bits |
    // | line_number: 16 bits | identifier_index: 16 bits | constant_index: 16 bits |
    return {
        version: Number((value >> 60n) & 0xfn),
        reserved: Number((value >> 56n) & 0xfn),
        error_code: Number((value >> 48n) & 0xffn),
        line_number: Number((value >> 32n) & 0xffffn),
        identifier_index: Number((value >> 16n) & 0xffffn),
        constant_index: Number(value & 0xffffn),
    };
}

/**
 * Formats the decoded error code as a readable string
 */
export function formatDecodedError(decoded: ReturnType<typeof decodeCleverErrorCode>): string {
    return JSON.stringify(decoded, null, 2);
}
