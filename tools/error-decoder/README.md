# Move Error Decoder

A web-based tool for decoding Move abort codes and parsing error messages from Sui/Move smart contracts.

## Features

### Tab 1: Parse Move Error String
- Parse full Move error strings to extract error information
- Output format: `Error : module::ErrorConstantName : Error message`
- Example: `Error : location::ESignatureVerificationFailed : Signature verification failed`


### Tab 2: Decode Abort Codes
- Decode abort codes (hex or decimal format) into their component fields:
  - `version` (4 bits)
  - `reserved` (4 bits)
  - `error_code` (8 bits)
  - `line_number` (16 bits)
  - `identifier_index` (16 bits)
  - `constant_index` (16 bits)

## Local Development

### Prerequisites
- Node.js 20+
- pnpm (or npm)

### Setup

1. Install dependencies:
```bash
pnpm install
```

2. Extract error constants from Move source files:
```bash
pnpm run extract:errors
```

3. Build the TypeScript files:
```bash
pnpm run build:decoder
```

4. Serve the application locally:
```bash
# Using Node.js serve
npx serve tools/error-decoder/dist

## Usage Examples

### Decoding an Abort Code

Input: `0xC002005600040005`

Output:
```json
{
  "version": 12,
  "reserved": 0,
  "error_code": 2,
  "line_number": 86,
  "identifier_index": 4,
  "constant_index": 5
}
```

### Parsing an Error String

Input:
```
MoveAbort(MoveLocation { module: ModuleId { address: 25ff0911b6fafe65e489acf1d02fbf4ca7eb64a6809f74c918b3fff1aa46b8ed, name: Identifier("location") }, function: 2, instruction: 32, function_name: Some("verify_proximity_proof_from_bytes") }, 0xC0050096000A000B) in command 0
```

Output:
```
Error : location::ESignatureVerificationFailed : Signature verification failed
```

The parser extracts the module name and error code, then looks up the error constant name and message from the error map.

## Error Constant Mapping

The tool automatically extracts error constants and their messages from Move source files in `contracts/world/sources/`. When you parse an error, it will show:
- The error constant name (e.g., `ESignatureVerificationFailed`)
- The error message (e.g., `Signature verification failed`)

To regenerate the error map after adding new error constants:
```bash
pnpm run extract:errors
```

This will update `error-map.ts` with the latest error definitions from your Move contracts.

## Deployment

The error decoder is automatically deployed to GitHub Pages when changes are pushed to the `main` branch in:
- `tools/error-decoder/` (decoder tool changes)
- `contracts/world/sources/` (Move contract changes that update error constants)
- `.github/workflows/deploy-decoder.yml` (workflow changes)

The deployed site will be available at: `https://[your-org].github.io/world-contracts/error-decoder/`

## How It Works

### Error Code Format

Move uses a "clever error code" format that packs multiple fields into a single u64:

```
| version: 4 bits | reserved: 4 bits | error_code: 8 bits |
| line_number: 16 bits | identifier_index: 16 bits | constant_index: 16 bits |
```

This allows Move to encode rich error information in a compact format.

**Important**: Abort codes must be full 64-bit values:
- Hex format: Exactly 16 hex digits (e.g., `0xC002005600040005`)
- Decimal format: Valid numbers within u64 range (0 to 2^64 - 1)

### Error Constant Extraction

The `error-extractor.ts` script:
1. Scans all `.move` files in `contracts/world/sources/`
2. Extracts module names and error constant definitions
3. Generates `error-map.ts` with a mapping of `module -> error_code -> constant_name`

This enables the web app to show human-readable error constant names instead of just numeric codes.
