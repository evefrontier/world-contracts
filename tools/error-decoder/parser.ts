import { decodeCleverErrorCode } from "./decoder.js";

/**
 * Extracts abort code from a Move error message string
 */
export function extractAbortCode(errorMessage: string): string | null {
    // Regex to match both hex (0x...) and decimal abort codes
    const match = errorMessage.match(/},\s*(0x[0-9a-fA-F]+|\d+)\)\s+in command/);
    if (!match) return null;

    return match[1];
}

/**
 * Parses a full Move error string and extracts all relevant information
 */
export interface ParsedError {
    moduleName: string;
    functionName: string;
    address: string;
    instruction: number;
    abortCode: string;
    decodedError: ReturnType<typeof decodeCleverErrorCode>;
    commandIndex: number;
}

// Note: This implementation is not perfect as it relies on regex pattern matching.
// TODO: If the Move error message format changes then change this pattern
export function parseMoveError(errorMessage: string): ParsedError | null {
    // Regex to match Move error format
    // Matches: MoveAbort(MoveLocation { module: ModuleId { address: ..., name: Identifier("module") },
    //          function: X, instruction: Y, function_name: Some("function") }, CODE) in command Z
    const re =
        /MoveAbort\(MoveLocation\s*{\s*module:\s*ModuleId\s*{\s*address:\s*([0-9a-f]+),\s*name:\s*Identifier\("([A-Za-z_]+)"\)\s*},\s*function:\s*(\d+),\s*instruction:\s*(\d+),\s*function_name:\s*Some\("([A-Za-z_]+)"\)\s*},\s*(0x[0-9a-fA-F]+|\d+)\)\s+in command\s*(\d+)/;

    let match = errorMessage.match(re);

    // if first regex doesn't match
    if (!match) {
        const altRe =
            /MoveAbort.*?address:\s*([0-9a-f]+).*?name:\s*Identifier\("([A-Za-z_]+)"\).*?function:\s*(\d+).*?instruction:\s*(\d+).*?function_name:\s*Some\("([A-Za-z_]+)"\).*?},\s*(0x[0-9a-fA-F]+|\d+)\).*?in command\s*(\d+)/s;
        match = errorMessage.match(altRe);
    }

    if (!match) {
        return null;
    }

    const [, address, moduleName, , instruction, functionName, abortCode, commandIndex] = match;

    // Validate and decode abort code
    let decodedError;
    try {
        decodedError = decodeCleverErrorCode(abortCode);
    } catch (error) {
        const errorMsg = error instanceof Error ? error.message : "Invalid format";
        throw new Error(`Failed to decode abort code "${abortCode}": ${errorMsg}`);
    }

    return {
        moduleName,
        functionName,
        address,
        instruction: parseInt(instruction, 10),
        abortCode,
        decodedError,
        commandIndex: parseInt(commandIndex, 10),
    };
}

/**
 * Formats the parsed error as a readable string
 */
export function formatParsedError(parsed: ParsedError): string {
    return JSON.stringify(
        {
            module: parsed.moduleName,
            function: parsed.functionName,
            address: parsed.address,
            instruction: parsed.instruction,
            abort_code: parsed.abortCode,
            decoded: parsed.decodedError,
            command_index: parsed.commandIndex,
        },
        null,
        2
    );
}
