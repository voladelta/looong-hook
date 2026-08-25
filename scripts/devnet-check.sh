#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
state=${DEVNET_STATE_DIR:-"$root/.devnet"}
owner_file="$state/anvil.owner"
owner_token="devnet-check-$$"
acquired_file="$state/devnet-check-acquired.$$"
ui_manifest=${DEVNET_UI_MANIFEST:-"$root/ui/public/deployment.json"}
startup_pid=
export DEVNET_OWNER_TOKEN="$owner_token"
export DEVNET_ACQUIRED_FILE="$acquired_file"

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM

    if [ -n "$startup_pid" ] && kill -0 "$startup_pid" 2>/dev/null; then
        kill "$startup_pid" 2>/dev/null || true
        wait "$startup_pid" 2>/dev/null || true
    fi

    recorded_owner=$(sed -n '1p' "$owner_file" 2>/dev/null || true)
    acquired_owner=$(sed -n '1p' "$acquired_file" 2>/dev/null || true)
    if [ "$recorded_owner" = "$owner_token" ]; then
        cleanup_status=0
        "$root/scripts/devnet-down.sh" || cleanup_status=$?
        if [ "$status" = "0" ] && [ "$cleanup_status" != "0" ]; then
            status=$cleanup_status
        fi
    fi

    if [ "$acquired_owner" = "$owner_token" ]; then
        rm -f -- "$ui_manifest"
    fi
    rm -f -- "$acquired_file"

    exit "$status"
}

on_signal() {
    exit 130
}

trap cleanup EXIT
trap on_signal HUP INT TERM

"$root/scripts/devnet-up.sh" &
startup_pid=$!
if wait "$startup_pid"; then
    startup_pid=
else
    status=$?
    startup_pid=
    exit "$status"
fi
"$root/scripts/devnet-deploy.sh"

cd "$root"
bun run scenario:devnet

"$root/scripts/devnet-down.sh"
echo "DEVNET_OK"
