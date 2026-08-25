#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
config="$root/.devnet/config.env"

[ -f "$config" ] || {
    echo "run ./scripts/devnet-up.sh first" >&2
    exit 1
}

. "$config"
export DEVNET_RPC_URL DEVNET_CHAIN_ID

cd "$root"
forge script script/DevnetDeploy.s.sol:DevnetDeployScript \
    --rpc-url "$DEVNET_RPC_URL" \
    --broadcast \
    --unlocked \
    --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

[ -f .devnet/deployment.json ] || {
    echo "DevnetDeployScript must write .devnet/deployment.json" >&2
    exit 1
}

cp -- .devnet/deployment.json ui/public/deployment.json
echo "devnet deployment written to .devnet/deployment.json"
