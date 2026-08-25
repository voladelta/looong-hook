#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
network=${1:-}
shift || true

[ -n "$network" ] || {
    echo "usage: $0 <network> --account <foundry-keystore-name>" >&2
    exit 1
}
[ "${CONFIRM_TESTNET_DEPLOY:-}" = "$network" ] || {
    echo "set CONFIRM_TESTNET_DEPLOY=$network after authorizing this broadcast" >&2
    exit 1
}
command -v jq >/dev/null 2>&1 || {
    echo "jq is required" >&2
    exit 1
}

manifest="$root/deployments/$network.json"
rpc_env=$(jq -r '.rpcEnv' "$manifest")
rpc_url=$(printenv "$rpc_env" || true)
[ -n "$rpc_url" ] || {
    echo "$rpc_env is required" >&2
    exit 1
}

cd "$root"
DEPLOYMENT_MANIFEST="$manifest" forge script script/TestnetDeploy.s.sol:TestnetDeployScript \
    --rpc-url "$rpc_url" \
    --broadcast \
    "$@"
