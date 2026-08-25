#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
network=${1:-}

[ -n "$network" ] || {
    echo "usage: $0 <network>" >&2
    exit 1
}
command -v jq >/dev/null 2>&1 || {
    echo "jq is required" >&2
    exit 1
}

manifest="$root/deployments/$network.json"
[ -f "$manifest" ] || {
    echo "missing $manifest" >&2
    exit 1
}

rpc_env=$(jq -r '.rpcEnv' "$manifest")
fork_block=$(jq -r '.forkBlock' "$manifest")
rpc_url=$(printenv "$rpc_env" || true)
[ -n "$rpc_url" ] || {
    echo "$rpc_env is required" >&2
    exit 1
}

cd "$root"
DEPLOYMENT_MANIFEST="$manifest" forge script script/TestnetDeploy.s.sol:TestnetDeployScript \
    --fork-url "$rpc_url" \
    --fork-block-number "$fork_block"
