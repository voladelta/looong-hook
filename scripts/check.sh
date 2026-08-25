#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

command -v forge >/dev/null 2>&1 || {
    echo "forge is required" >&2
    exit 1
}

run_step() {
    name=$1
    shift
    echo "==> $name"
    if "$@"; then
        echo "<== PASS: $name"
        return 0
    else
        status=$?
        echo "<== FAIL: $name (exit $status)" >&2
        exit "$status"
    fi
}

run_step "forge format" forge fmt --check
run_step "forge build and sizes" forge build --sizes
run_step "forge tests" forge test
run_step "devnet startup cleanup" "$root/scripts/test-devnet-startup-cleanup.sh"

if command -v slither >/dev/null 2>&1; then
    run_step "slither fail-high" slither . --filter-paths 'vendor/' --fail-high
elif [ "${REQUIRE_SLITHER:-0}" = "1" ]; then
    echo "slither is required when REQUIRE_SLITHER=1" >&2
    exit 1
else
    echo "slither: skipped (set REQUIRE_SLITHER=1 to make it mandatory)" >&2
fi

if [ "${SKIP_APP:-0}" != "1" ]; then
    command -v bun >/dev/null 2>&1 || {
        echo "bun is required for app checks (or set SKIP_APP=1 for a contract-only task)" >&2
        exit 1
    }
    [ -x node_modules/.bin/tsc ] || {
        echo "run bun install --frozen-lockfile before ./scripts/check.sh" >&2
        exit 1
    }
    run_step "TypeScript typecheck" bun run typecheck
    run_step "Vite production build" bun run ui:build
fi

echo "CHECK_OK"
