#!/bin/bash

# Deploy script for World Contracts
# Publishes contracts, extracts package ID, and creates admin capabilities

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

# Create admin capabilities
echo "Creating admin capabilities..."
ADMIN_CAP_IDS=()

# Parse admin addresses (comma-separated)
if [ -z "$ADMIN_ADDRESS" ]; then
    echo "Warning: No admin addresses found in ADMIN_ADDRESS env variable"
else
    # Split by comma using IFS
    IFS=',' read -ra ADMIN_ADDRS <<< "$ADMIN_ADDRESS"
    
    for ADMIN_ADDR in "${ADMIN_ADDRS[@]}"; do
        # Trim whitespace
        ADMIN_ADDR=$(echo "$ADMIN_ADDR" | xargs)
        
        echo "Creating AdminCap for: $ADMIN_ADDR"
        
        # Call create_admin_cap function
        ADMIN_CAP_OUTPUT=$(sui client call \
            --package $PACKAGE_ID \
            --module authority \
            --function create_admin_cap \
            --args $GOVERNOR_CAP_ID $ADMIN_ADDR \
            --gas-budget ${GAS_BUDGET:-100000000} \
            --json)
        
        # Save admin cap output for debugging
        echo "$ADMIN_CAP_OUTPUT" > "deployments/.output/${ENV}-admin-cap-${ADMIN_ADDR}.json"
        
        # Check if admin cap creation was successful
        ADMIN_CAP_STATUS=$(echo "$ADMIN_CAP_OUTPUT" | jq -r '.effects.status.status // "unknown"')
        
        if [ "$ADMIN_CAP_STATUS" != "success" ]; then
            echo "Warning: Failed to create AdminCap for $ADMIN_ADDR (status: $ADMIN_CAP_STATUS)"
            continue
        fi
        
        # Extract AdminCap ID
        ADMIN_CAP_ID=$(echo "$ADMIN_CAP_OUTPUT" | jq -r '.objectChanges[] | select(.objectType != null and (.objectType | contains("AdminCap"))) | .objectId')
        
        if [ -z "$ADMIN_CAP_ID" ] || [ "$ADMIN_CAP_ID" = "null" ]; then
            echo "Warning: Failed to extract AdminCap ID for $ADMIN_ADDR"
        else
            ADMIN_CAP_IDS+=("{\"address\": \"$ADMIN_ADDR\", \"adminCapId\": \"$ADMIN_CAP_ID\"}")
            echo "AdminCap created: $ADMIN_CAP_ID"
        fi
    done
fi

echo ""

# Build admin caps JSON array
ADMIN_CAPS_JSON="[]"
if [ ${#ADMIN_CAP_IDS[@]} -gt 0 ]; then
    ADMIN_CAPS_JSON=$(printf '%s\n' "${ADMIN_CAP_IDS[@]}" | jq -s '.')
fi

# Save deployment info to JSON file
cat > "$OUTPUT_FILE" << EOF
{
  "network": "$ENV",
  "deployedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "deployedBy": "$ACTIVE_ADDRESS",
  "packageId": "$PACKAGE_ID",
  "governorCapId": "$GOVERNOR_CAP_ID",
  "adminCaps": $ADMIN_CAPS_JSON
}
EOF

echo "======================================"
echo "Deployment Complete!"
echo "======================================"
echo "Package ID: $PACKAGE_ID"
echo "GovernorCap ID: $GOVERNOR_CAP_ID"
echo "Admin Caps Created: ${#ADMIN_CAP_IDS[@]}"
echo ""
echo "Deployment info saved to: $OUTPUT_FILE"
echo "Debug files saved to: deployments/.output/${ENV}-*.json"
echo ""
cat "$OUTPUT_FILE"