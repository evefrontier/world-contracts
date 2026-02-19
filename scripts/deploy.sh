#!/bin/bash

# Deploy script for World Contracts
# Publishes contracts, extracts package ID, and adds sponsors to AdminACL

set -e  # Exit on error

# Load environment variables
if [ -f .env ]; then
    # Use set -a to automatically export all variables
    set -a
    source .env
    set +a
else
    echo "Error: .env file not found. Copy env.example to .env and configure it."
    exit 1
fi

# Contract Directory
CONTRACT_DIR="contracts/world"

# Check dependencies
for dep in jq sui; do
    if ! command -v ${dep} &> /dev/null; then
        echo "Error: Please install ${dep}"
        exit 1
    fi
done

# Process command line args
ENV=${SUI_NETWORK:-localnet}
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
    --env=*)
        ENV="${1#*=}"
        ;;
    --dry-run)
        DRY_RUN=true
        ;;
    *)
        echo "Unknown argument: $1"
        echo "Usage: $0 [--env=<devnet|testnet|localnet|mainnet>] [--dry-run]"
        exit 1
    esac
    shift
done

# Validate environment
case "$ENV" in
    testnet|devnet|localnet|mainnet) ;;
    *)
        echo "Error: Invalid environment '$ENV'. Must be testnet, devnet, localnet, or mainnet"
        exit 1
    ;;
esac

echo "======================================"
echo "Deploying to: $ENV"
echo "======================================"

# Determine RPC URL based on environment
case "$ENV" in
    testnet)
        RPC_URL="https://fullnode.testnet.sui.io:443"
        ;;
    devnet)
        RPC_URL="https://fullnode.devnet.sui.io:443"
        ;;
    localnet)
        RPC_URL="http://127.0.0.1:9000"
        ;;
    mainnet)
        RPC_URL="https://fullnode.mainnet.sui.io:443"
        ;;
esac

# Initialize Sui client config if it doesn't exist, this setting is mostly for the docker deployment
if [ ! -f "$HOME/.sui/sui_config/client.yaml" ]; then
    echo "Initializing Sui client configuration..."
    
    # Create directory if it doesn't exist
    mkdir -p "$HOME/.sui/sui_config"
    
    # Create minimal client.yaml to avoid interactive prompts
    cat > "$HOME/.sui/sui_config/client.yaml" << EOF
---
keystore:
  File: $HOME/.sui/sui_config/sui.keystore
envs:
  - alias: $ENV
    rpc: "$RPC_URL"
    ws: ~
    basic_auth: ~
active_env: $ENV
active_address: ~
EOF
    echo "Created Sui client configuration for $ENV"
else
    # Check if the environment exists in the config
    echo "Checking Sui client configuration..."
    if ! sui client envs 2>/dev/null | grep -qw "$ENV"; then
        echo "Adding $ENV environment to Sui config..."
        set +e
        ENV_ADD_OUTPUT=$(sui client new-env --alias $ENV --rpc $RPC_URL 2>&1)
        ENV_ADD_EXIT=$?
        set -e
        
        # Ignore error if environment already exists
        if [ $ENV_ADD_EXIT -ne 0 ] && ! echo "$ENV_ADD_OUTPUT" | grep -qi "already exists"; then
            echo "Error: Failed to add $ENV environment"
            echo "$ENV_ADD_OUTPUT"
            exit 1
        fi
    fi
fi

# Switch to the target environment
echo "Switching to $ENV environment..."
sui client switch --env $ENV

# Verify we're on the correct network
ACTIVE_ENV=$(sui client active-env 2>/dev/null || echo "unknown")
if [ "$ACTIVE_ENV" != "$ENV" ]; then
    echo "Error: Failed to switch to $ENV (currently on $ACTIVE_ENV)"
    echo "Please check your Sui configuration"
    exit 1
fi
echo "Using $ENV environment"
echo ""

# Import mnemonic if provided
if [ -n "$MNEMONIC" ]; then
    echo "Importing wallet from mnemonic..."
    
    set +e
    IMPORT_OUTPUT=$(sui keytool import "$MNEMONIC" ${KEY_SCHEME:-ed25519} 2>&1)
    IMPORT_EXIT_CODE=$?
    set -e
    
    # Handle import result
    if [ $IMPORT_EXIT_CODE -ne 0 ] && ! echo "$IMPORT_OUTPUT" | grep -qi "already exists"; then
        echo "Error: Failed to import mnemonic"
        echo "$IMPORT_OUTPUT"
        exit 1
    fi
    
    # Extract imported address
    IMPORTED_ADDRESS=$(echo "$IMPORT_OUTPUT" | grep -oE '0x[a-fA-F0-9]{64}' | head -n 1)
    if [ -n "$IMPORTED_ADDRESS" ]; then
        echo "Using imported address: $IMPORTED_ADDRESS"
        # Switch to the imported address
        sui client switch --address "$IMPORTED_ADDRESS"
    fi
    echo ""
fi

if [ "$DRY_RUN" = true ]; then
    echo "Dry run - exiting without publishing"
    exit 0
fi

# Get active address
ACTIVE_ADDRESS=$(sui client active-address)
echo "Active address: $ACTIVE_ADDRESS"
echo ""

# Create output directories
mkdir -p deployments/.output
OUTPUT_FILE="deployments/${ENV}-deployment.json"

# Publish the world package
echo "Publishing world package..."
cd $CONTRACT_DIR
PUBLISH_OUTPUT=$(sui client publish --gas-budget ${GAS_BUDGET:-100000000} --json)
cd ../..

# Save publish output for debugging
echo "$PUBLISH_OUTPUT" > "deployments/.output/${ENV}-publish-output.json"

# Check if publish was successful by examining the status field
PUBLISH_STATUS=$(echo "$PUBLISH_OUTPUT" | jq -r '.effects.status.status // "unknown"')

if [ "$PUBLISH_STATUS" != "success" ]; then
    echo "Error: Failed to publish world package (status: $PUBLISH_STATUS)"
    cat "deployments/.output/${ENV}-publish-output.json"
    exit 1
fi

# Extract package ID
PACKAGE_ID=$(echo "$PUBLISH_OUTPUT" | jq -r '.objectChanges[] | select(.type == "published") | .packageId')

if [ -z "$PACKAGE_ID" ] || [ "$PACKAGE_ID" = "null" ]; then
    echo "Error: Failed to extract package ID"
    cat "deployments/.output/${ENV}-publish-output.json"
    exit 1
fi

echo "Package published: $PACKAGE_ID"

# Extract GovernorCap ID
GOVERNOR_CAP_ID=$(echo "$PUBLISH_OUTPUT" | jq -r '.objectChanges[] | select(.objectType != null and (.objectType | contains("GovernorCap"))) | .objectId')

if [ -z "$GOVERNOR_CAP_ID" ] || [ "$GOVERNOR_CAP_ID" = "null" ]; then
    echo "Error: Failed to extract GovernorCap ID"
    cat "deployments/.output/${ENV}-publish-output.json"
    exit 1
fi

echo "GovernorCap ID: $GOVERNOR_CAP_ID"
echo ""

# Save deployment info to JSON file
cat > "$OUTPUT_FILE" << EOF
{
  "network": "$ENV",
  "deployedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "deployedBy": "$ACTIVE_ADDRESS",
  "packageId": "$PACKAGE_ID",
  "governorCapId": "$GOVERNOR_CAP_ID"
}
EOF

echo "======================================"
echo "Deployment Complete!"
echo "======================================"
echo "Package ID: $PACKAGE_ID"
echo "GovernorCap ID: $GOVERNOR_CAP_ID"
echo ""
echo "Next: run 'npm run extract-object-ids' then 'npm run setup-access' to configure sponsors."
echo ""
echo "Deployment info saved to: $OUTPUT_FILE"
echo "Debug files saved to: deployments/.output/${ENV}-*.json"
echo ""
cat "$OUTPUT_FILE"