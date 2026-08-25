#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
state=${DEVNET_STATE_DIR:-"$root/.devnet"}
pid_file="$state/anvil.pid"
owner_file="$state/anvil.owner"
log_file="$state/anvil.log"
port=${DEVNET_PORT:-8545}
chain_id=${DEVNET_CHAIN_ID:-31337}
ready_attempts=${DEVNET_READY_ATTEMPTS:-50}
startup_delay=${DEVNET_STARTUP_DELAY:-0}
anvil_bin=${DEVNET_ANVIL_BIN:-anvil}
cast_bin=${DEVNET_CAST_BIN:-cast}
owner_token=${DEVNET_OWNER_TOKEN:-manual-$$}
acquired_file=${DEVNET_ACQUIRED_FILE:-}
mnemonic="test test test test test test test test test test test junk"

command -v "$anvil_bin" >/dev/null 2>&1 || {
    echo "anvil is required" >&2
    exit 1
}
command -v "$cast_bin" >/dev/null 2>&1 || {
    echo "cast is required" >&2
    exit 1
}

mkdir -p -- "$state"
if [ -f "$pid_file" ] && kill -0 "$(sed -n '1p' "$pid_file")" 2>/dev/null; then
    echo "devnet already running on PID $(sed -n '1p' "$pid_file")" >&2
    exit 1
fi
rm -f -- "$pid_file" "$owner_file" "$state/config.env"

spawned=0
cleanup_startup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ "$spawned" = "1" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rm -f -- "$pid_file" "$owner_file" "$state/config.env"
    fi
    exit "$status"
}

on_signal() {
    exit 130
}

trap cleanup_startup EXIT
trap on_signal HUP INT TERM

if [ -n "$acquired_file" ]; then
    printf '%s\n' "$owner_token" >"$acquired_file"
fi

"$anvil_bin" \
    --host 127.0.0.1 \
    --port "$port" \
    --chain-id "$chain_id" \
    --accounts 100 \
    --balance 100000 \
    --mnemonic "$mnemonic" \
    --silent >"$log_file" 2>&1 &
pid=$!
spawned=1
printf '%s\n' "$pid" >"$pid_file"
printf '%s\n' "$owner_token" >"$owner_file"

if [ "$startup_delay" != "0" ]; then
    sleep "$startup_delay"
fi

rpc_url="http://127.0.0.1:$port"
attempt=0
while ! "$cast_bin" chain-id --rpc-url "$rpc_url" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$ready_attempts" ]; then
        echo "anvil did not become ready; inspect $log_file" >&2
        exit 1
    fi
    sleep 0.1
done

cat >"$state/config.env" <<EOF
DEVNET_RPC_URL=$rpc_url
DEVNET_CHAIN_ID=$chain_id
DEVNET_MNEMONIC='$mnemonic'
EOF

spawned=0
trap - EXIT HUP INT TERM
echo "devnet ready at $rpc_url with PID $pid and 100 disposable accounts"
