#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/v4hook-devnet-cleanup.XXXXXX")
signal_state="$tmp/signal-state"
failure_state="$tmp/failure-state"
preexisting_state="$tmp/preexisting-state"
occupied_state="$tmp/occupied-state"
probe_state="$tmp/probe-state"
signal_ui="$tmp/signal-ui/deployment.json"
failure_ui="$tmp/failure-ui/deployment.json"
preexisting_ui="$tmp/preexisting-ui/deployment.json"
port_base=$((20000 + ($$ % 10000)))
signal_port=$port_base
failure_port=$((port_base + 1))
preexisting_port=$((port_base + 2))

cleanup() {
    for state in "$signal_state" "$failure_state" "$preexisting_state" "$occupied_state" "$probe_state"; do
        if [ -f "$state/anvil.pid" ]; then
            pid=$(sed -n '1p' "$state/anvil.pid")
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -rf -- "$tmp"
}
trap cleanup EXIT HUP INT TERM

assert_stopped() {
    state=$1
    output=$2
    owned_pid=$3
    port=$4
    ui_manifest=$5
    if kill -0 "$owned_pid" 2>/dev/null; then
        echo "owned anvil PID $owned_pid survived cleanup" >&2
        exit 1
    fi
    [ ! -e "$state/anvil.pid" ] || { echo "stale PID file" >&2; exit 1; }
    [ ! -e "$state/anvil.owner" ] || { echo "stale owner file" >&2; exit 1; }
    [ ! -e "$state/config.env" ] || { echo "stale config file" >&2; exit 1; }
    [ ! -e "$state/deployment.json" ] || { echo "stale deployment manifest" >&2; exit 1; }
    if [ -d "$state" ] && find "$state" -name 'devnet-check-acquired.*' -print -quit | grep -q .; then
        echo "stale acquisition receipt" >&2
        exit 1
    fi
    [ ! -e "$ui_manifest" ] || { echo "stale UI manifest" >&2; exit 1; }
    ! cast chain-id --rpc-url "http://127.0.0.1:$port" >/dev/null 2>&1 || {
        echo "owned devnet port $port survived cleanup" >&2
        exit 1
    }
    ! grep -q 'DEVNET_OK' "$output" || { echo "false DEVNET_OK sentinel" >&2; exit 1; }
}

signal_output="$tmp/signal.out"
mkdir -p -- "$(dirname -- "$signal_ui")"
printf '%s\n' stale >"$signal_ui"
DEVNET_STATE_DIR="$signal_state" DEVNET_UI_MANIFEST="$signal_ui" \
    DEVNET_PORT="$signal_port" DEVNET_STARTUP_DELAY=10 "$root/scripts/devnet-check.sh" >"$signal_output" 2>&1 &
wrapper_pid=$!
signal_receipt="$signal_state/devnet-check-acquired.$wrapper_pid"
attempt=0
while [ ! -f "$signal_state/anvil.pid" ] || [ ! -f "$signal_receipt" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 50 ] || { echo "signal test never observed startup ownership" >&2; exit 1; }
    sleep 0.1
done
signal_anvil_pid=$(sed -n '1p' "$signal_state/anvil.pid")
kill -TERM "$wrapper_pid"
signal_status=0
wait "$wrapper_pid" || signal_status=$?
[ "$signal_status" = "130" ] || { echo "signal status was $signal_status, expected 130" >&2; exit 1; }
assert_stopped "$signal_state" "$signal_output" "$signal_anvil_pid" "$signal_port" "$signal_ui"

failure_output="$tmp/failure.out"
failure_status=0
mkdir -p -- "$(dirname -- "$failure_ui")"
printf '%s\n' stale >"$failure_ui"
DEVNET_STATE_DIR="$failure_state" DEVNET_UI_MANIFEST="$failure_ui" \
    DEVNET_PORT="$failure_port" DEVNET_CAST_BIN=false DEVNET_READY_ATTEMPTS=10 \
    "$root/scripts/devnet-check.sh" >"$failure_output" 2>&1 &
failure_wrapper_pid=$!
failure_receipt="$failure_state/devnet-check-acquired.$failure_wrapper_pid"
attempt=0
while [ ! -f "$failure_state/anvil.pid" ] || [ ! -f "$failure_receipt" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 50 ] || { echo "failure test never observed startup ownership" >&2; exit 1; }
    sleep 0.1
done
failure_anvil_pid=$(sed -n '1p' "$failure_state/anvil.pid")
wait "$failure_wrapper_pid" || failure_status=$?
[ "$failure_status" = "1" ] || { echo "readiness status was $failure_status, expected 1" >&2; exit 1; }
assert_stopped "$failure_state" "$failure_output" "$failure_anvil_pid" "$failure_port" "$failure_ui"

preexisting_output="$tmp/preexisting.out"
mkdir -p -- "$(dirname -- "$preexisting_ui")"
DEVNET_STATE_DIR="$preexisting_state" DEVNET_UI_MANIFEST="$preexisting_ui" \
    DEVNET_PORT="$preexisting_port" DEVNET_OWNER_TOKEN=preexisting \
    "$root/scripts/devnet-up.sh" >"$preexisting_output" 2>&1
preexisting_pid=$(sed -n '1p' "$preexisting_state/anvil.pid")
printf '%s\n' preserved >"$preexisting_ui"
intruder_status=0
DEVNET_STATE_DIR="$preexisting_state" DEVNET_UI_MANIFEST="$preexisting_ui" \
    DEVNET_PORT="$preexisting_port" DEVNET_OWNER_TOKEN=intruder \
    "$root/scripts/devnet-check.sh" >>"$preexisting_output" 2>&1 || intruder_status=$?
[ "$intruder_status" = "1" ] || { echo "pre-existing devnet status was $intruder_status, expected 1" >&2; exit 1; }
kill -0 "$preexisting_pid" 2>/dev/null || { echo "pre-existing anvil was stopped" >&2; exit 1; }
cast chain-id --rpc-url "http://127.0.0.1:$preexisting_port" >/dev/null 2>&1 || {
    echo "pre-existing devnet port was stopped" >&2
    exit 1
}
[ -f "$preexisting_ui" ] || { echo "pre-existing manifest was removed" >&2; exit 1; }
! grep -q 'DEVNET_OK' "$preexisting_output" || { echo "false pre-existing DEVNET_OK sentinel" >&2; exit 1; }

# A node with a different state directory must also prevent startup, even on the expected chain.
occupied_status=0
DEVNET_STATE_DIR="$occupied_state" DEVNET_PORT="$preexisting_port" \
    "$root/scripts/devnet-up.sh" >"$tmp/occupied.out" 2>&1 || occupied_status=$?
[ "$occupied_status" = "1" ] || { echo "occupied port was accepted" >&2; exit 1; }
grep -q 'port .* already has a listener' "$tmp/occupied.out"
kill -0 "$preexisting_pid"
[ ! -e "$occupied_state/anvil.pid" ]
[ ! -e "$occupied_state/config.env" ]

DEVNET_STATE_DIR="$preexisting_state" DEVNET_UI_MANIFEST="$preexisting_ui" \
    DEVNET_OWNER_TOKEN=preexisting "$root/scripts/devnet-down.sh" >>"$preexisting_output" 2>&1
assert_stopped "$preexisting_state" "$preexisting_output" "$preexisting_pid" "$preexisting_port" "$preexisting_ui"

# Stub only the external process/RPC boundary; exercise the actual startup script.
cat >"$tmp/rpc-chain" <<'EOF'
#!/bin/sh
echo "${TEST_RPC_CHAIN:-31337}"
EOF
cat >"$tmp/idle-anvil" <<'EOF'
#!/bin/sh
exec sleep 30
EOF
chmod +x "$tmp/rpc-chain" "$tmp/idle-anvil"

for probe in dead wrong-chain no-listener; do
    probe_status=0
    probe_anvil=anvil
    probe_chain=31337
    case "$probe" in
        dead) probe_anvil=false ;;
        wrong-chain) probe_chain=1 ;;
        no-listener) probe_anvil="$tmp/idle-anvil" ;;
    esac
    TEST_RPC_CHAIN="$probe_chain" DEVNET_STATE_DIR="$probe_state" DEVNET_PORT="$failure_port" \
        DEVNET_ANVIL_BIN="$probe_anvil" DEVNET_CAST_BIN="$tmp/rpc-chain" DEVNET_READY_ATTEMPTS=10 \
        "$root/scripts/devnet-up.sh" >"$tmp/$probe.out" 2>&1 || probe_status=$?
    [ "$probe_status" = "1" ] || { echo "$probe readiness was accepted" >&2; exit 1; }
    [ ! -e "$probe_state/anvil.pid" ]
    [ ! -e "$probe_state/anvil.owner" ]
    [ ! -e "$probe_state/config.env" ]
    [ -z "$(lsof -nP -tiTCP:"$failure_port" -sTCP:LISTEN 2>/dev/null || true)" ]
done

echo "DEVNET_STARTUP_CLEANUP_OK"
