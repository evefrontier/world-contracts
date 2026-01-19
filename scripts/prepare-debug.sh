#!/bin/bash

# Prepare debug environment for on-chain transaction debugging
# Usage: ./scripts/prepare-debug.sh <TRANSACTION_DIGEST>

set -e

if [ $# -eq 0 ]; then
    echo "Error: Transaction digest is required"
    echo "Usage: $0 <TRANSACTION_DIGEST>"
    exit 1
fi

TRANSACTION_DIGEST=$1
PACKAGE_DIR="contracts/world"
REPLAY_DIR=".replay/$TRANSACTION_DIGEST"
PACKAGE_NAME="World"

# Step 1: Generate execution traces
echo "Generating execution traces..."
# Note: Ignore error if trace file already exists (replay may fail with exit code 1)
sui replay --trace --digest "$TRANSACTION_DIGEST" || true

# Check if replay directory and trace file exist (ignore replay error if already exists)
if [ ! -d "$REPLAY_DIR" ] || [ ! -f "$REPLAY_DIR/trace.json.zst" ]; then
    echo "Error: Failed to generate replay directory or trace file"
    exit 1
fi

# Step 2: Build Move package
echo "Building Move package..."
cd "$PACKAGE_DIR"
sui move build

BUILD_DIR="build/$PACKAGE_NAME"
if [ ! -d "$BUILD_DIR" ]; then
    echo "Error: Build directory not found: $BUILD_DIR"
    exit 1
fi

cd ../..

# Step 3: Find package ID and copy build artifacts
echo "Copying build artifacts..."

# Find package ID from replay directory
PACKAGE_ID=$(find "$REPLAY_DIR" -maxdepth 1 -type d -name "0x*" | head -n 1 | xargs basename)

if [ -z "$PACKAGE_ID" ]; then
    echo "Error: No package ID found in $REPLAY_DIR"
    exit 1
fi

TARGET_DIR="$REPLAY_DIR/$PACKAGE_ID/source"
mkdir -p "$TARGET_DIR"
cp -r "$PACKAGE_DIR/$BUILD_DIR"/* "$TARGET_DIR/"

echo "Done! Build artifacts copied to: $TARGET_DIR"
echo "Open $REPLAY_DIR/trace.json.zst in VS Code and start debugging (F5)"
