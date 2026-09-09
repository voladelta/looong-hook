#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

port=${TESTNET_SENDER_PORT:-18548}
export TESTNET_SENDER_RPC_URL="http://127.0.0.1:$port"
creator=0x000000000000000000000000000000000000beef
network="testnet-sender-local-$$"
manifest="deployments/$network.json"
stale_manifest=".devnet/testnet-sender-stale.json"
mkdir -p .devnet

# Only an isolated localhost node is used. Its unlocked fixture account needs no keystore.
if cast block-number --rpc-url "$TESTNET_SENDER_RPC_URL" >/dev/null 2>&1; then
    echo "localhost port $port is already in use" >&2
    exit 1
fi
anvil --port "$port" --silent > .devnet/testnet-sender-anvil.log 2>&1 &
anvil_pid=$!
trap 'kill "$anvil_pid" 2>/dev/null || true; rm -f "$manifest" "$stale_manifest"' EXIT HUP INT TERM
attempt=0
until cast block-number --rpc-url "$TESTNET_SENDER_RPC_URL" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || exit 1
    kill -0 "$anvil_pid"
    sleep 0.1
done
kill -0 "$anvil_pid"

cast rpc --rpc-url "$TESTNET_SENDER_RPC_URL" anvil_setBalance "$creator" 0x3635c9adc5dea00000 >/dev/null
cast rpc --rpc-url "$TESTNET_SENDER_RPC_URL" anvil_setNonce "$creator" 0x7 >/dev/null
forge script test/integration/TestnetDeploy.t.sol:TestnetDeployFixture \
    --rpc-url "$TESTNET_SENDER_RPC_URL" \
    --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --broadcast --unlocked \
    > .devnet/testnet-sender-fixture.log 2>&1
jq --argjson block "$(cast block-number --rpc-url "$TESTNET_SENDER_RPC_URL")" \
    '.forkBlock = $block' .devnet/testnet-sender.json > "$manifest"

./scripts/testnet-dry-run.sh "$network" > .devnet/testnet-sender-dry-run.log 2>&1
artifact=broadcast/TestnetDeploy.s.sol/31337/dry-run/run-latest.json
expected_coordinator=$(jq -r '.root.expectedCoordinator' "$manifest")
expected_token=$(jq -r '.token.expectedAddress' "$manifest")
jq -e --arg creator "$creator" --arg coordinator "$expected_coordinator" --arg token "$expected_token" '
    .transactions as $tx |
    ($tx | length) == 4 and
    all($tx[]; .transaction.from == $creator) and
    ($tx | map(.transaction.nonce)) == ["0x7", "0x8", "0x9", "0xa"] and
    $tx[0].contractName == "LooongRouter" and
    $tx[1].contractName == "LooongHookFactory" and
    $tx[2].contractName == "LooongMarketCoordinatorV1" and
    ($tx[2].contractAddress | ascii_downcase) == ($coordinator | ascii_downcase) and
    ($tx[0].arguments[1] | ascii_downcase) == $tx[2].contractAddress and
    ($tx[1].arguments[1] | ascii_downcase) == $tx[2].contractAddress and
    ($tx[1].arguments[2] | ascii_downcase) == $tx[0].contractAddress and
    ($tx[2].arguments[3] | ascii_downcase) == $tx[0].contractAddress and
    ($tx[2].arguments[4] | ascii_downcase) == $tx[1].contractAddress and
    $tx[3].contractAddress == $tx[2].contractAddress and
    ($tx[3].arguments[1] | ascii_downcase) == ($token | ascii_downcase)
' "$artifact" >/dev/null

if DEPLOYMENT_MANIFEST="$manifest" forge script script/TestnetDeploy.s.sol:TestnetDeployScript \
    --rpc-url "$TESTNET_SENDER_RPC_URL" --sender 0x000000000000000000000000000000000000cAFE \
    -vvvv > .devnet/testnet-sender-wrong.log 2>&1; then
    echo "wrong sender was accepted" >&2
    exit 1
fi
rg -q 'CreatorSenderMismatch' .devnet/testnet-sender-wrong.log
if sed -n '/TestnetDeployScript::run()/,$p' .devnet/testnet-sender-wrong.log | rg -q '→ new '; then
    echo "wrong sender reached contract creation" >&2
    exit 1
fi

jq '.root.expectedCoordinator = "0x000000000000000000000000000000000000cafe"' \
    "$manifest" > "$stale_manifest"
if DEPLOYMENT_MANIFEST="$stale_manifest" forge script script/TestnetDeploy.s.sol:TestnetDeployScript \
    --rpc-url "$TESTNET_SENDER_RPC_URL" --sender "$creator" \
    -vvvv > .devnet/testnet-sender-stale.log 2>&1; then
    echo "stale coordinator prediction was accepted" >&2
    exit 1
fi
rg -q 'InvalidManifest' .devnet/testnet-sender-stale.log
if sed -n '/TestnetDeployScript::run()/,$p' .devnet/testnet-sender-stale.log | rg -q '→ new '; then
    echo "stale coordinator prediction reached contract creation" >&2
    exit 1
fi
[ "$(cast nonce --rpc-url "$TESTNET_SENDER_RPC_URL" "$creator")" = 7 ]
echo TESTNET_SENDER_OK
