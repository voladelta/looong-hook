#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
target="$root/references/foundry"
stage=$(mktemp -d "${TMPDIR:-/tmp}/v4hook-foundry-docs.XXXXXX")

cleanup() {
    rm -rf -- "$stage"
}
trap cleanup EXIT HUP INT TERM

fetch() {
    route=$1
    output=$2
    curl -fsSL "https://getfoundry.sh/$route" -o "$stage/$output"
    [ -s "$stage/$output" ] || {
        echo "empty Foundry reference: $route" >&2
        exit 1
    }
    if [ "${output##*.}" = "md" ]; then
        sed -E 's/[[:blank:]]+$//' "$stage/$output" >"$stage/$output.normalized"
        mv -- "$stage/$output.normalized" "$stage/$output"
    fi
}

fetch "llms.txt" "llms.txt"
fetch "introduction/agents.md" "agents.md"
fetch "forge/testing.md" "testing.md"
fetch "guides/invariant-testing.md" "invariant-testing.md"
fetch "config/testing.md" "testing-configuration.md"
fetch "config/compiler.md" "compiler-configuration.md"
fetch "forge/scripting.md" "scripting.md"
fetch "forge/gas-tracking.md" "gas-tracking.md"
fetch "forge/linting.md" "linting.md"
fetch "anvil/state-management.md" "anvil-state-management.md"
fetch "anvil/custom-methods.md" "anvil-custom-methods.md"
fetch "guides/stack-too-deep.md" "stack-too-deep.md"
fetch "guides/deterministic-deployments-using-create2.md" "deterministic-deployments.md"

for source in "$stage"/*; do
    cp -- "$source" "$target/$(basename "$source")"
done

echo "Foundry references refreshed; review the diff and update references/foundry/README.md provenance"
