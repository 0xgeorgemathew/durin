#!/bin/bash
source .env

if [ -z "$ETHERSCAN_API_KEY" ] || [ -z "$L2_REGISTRY_ADDRESS" ] || [ -z "$L2_RPC_URL" ]; then
    echo "Error: Missing required environment variables. Please check your .env file."
    exit 1
fi

CONTRACT_NAME="MoonjoyL2Registrar"
CONTRACT_FILE="src/MoonjoyL2Registrar.sol"

echo "Building the project..."
forge build

echo "Deploying $CONTRACT_NAME from $CONTRACT_FILE..."
DEPLOY_OUTPUT=$(forge create \
    --rpc-url "${L2_RPC_URL}" \
    --verify \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --interactive \
    --broadcast \
    $CONTRACT_FILE:$CONTRACT_NAME \
    --constructor-args "$L2_REGISTRY_ADDRESS")

echo "$DEPLOY_OUTPUT"

if [ "$AUTO_ADD_REGISTRAR" = "1" ]; then
    REGISTRAR_ADDRESS=$(printf '%s\n' "$DEPLOY_OUTPUT" | awk '/Deployed to:/ { print $3 }' | tail -n 1)

    if [ -z "$REGISTRAR_ADDRESS" ]; then
        echo "Error: Could not parse deployed registrar address."
        exit 1
    fi

    echo "Adding registrar $REGISTRAR_ADDRESS to L2Registry $L2_REGISTRY_ADDRESS..."

    CAST_SEND_ARGS=(
        cast send
        --rpc-url "${L2_RPC_URL}" \
        "${L2_REGISTRY_ADDRESS}" \
        "addRegistrar(address)" \
        "$REGISTRAR_ADDRESS"
    )

    if [ -n "${REGISTRY_ADMIN_PRIVATE_KEY:-}" ]; then
        CAST_SEND_ARGS+=(
            --private-key "${REGISTRY_ADMIN_PRIVATE_KEY}"
        )
    else
        CAST_SEND_ARGS+=(
            --interactive
        )
    fi

    "${CAST_SEND_ARGS[@]}"
fi
