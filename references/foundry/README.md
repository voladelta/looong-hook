# Foundry reference snapshots

Use local project evidence and installed command help first. These snapshots are the next stop when
the task needs Foundry workflow or configuration guidance without a broad documentation search.

| Need | Snapshot |
| --- | --- |
| Retrieval order and version checks | `agents.md` |
| Forge tests and debugging | `testing.md` |
| Handler invariants and ghost state | `invariant-testing.md` |
| Fuzz/invariant configuration | `testing-configuration.md` |
| Optimizer, compiler and IR settings | `compiler-configuration.md` |
| Scripts and transaction simulation | `scripting.md` |
| Gas snapshots and reports | `gas-tracking.md` |
| Lint findings and annotations | `linting.md` |
| Local chain snapshots and control | `anvil-state-management.md`, `anvil-custom-methods.md` |
| Compiler stack pressure | `stack-too-deep.md` |
| CREATE2 deployments | `deterministic-deployments.md` |
| A route not listed above | search `llms.txt`, then retrieve only that page |

The snapshots were retrieved from the official [Foundry documentation](https://getfoundry.sh/) on
2026-08-21. `llms.txt` had ETag `0912ee55e422bf8472f5c89033890635` and SHA-256
`eecd45cffa432b72bd1793e7b13ca15d51a4ebaa600d98da62b977862cceb3af`. The local verification
version at capture time was Foundry 1.7.1, commit
`4072e48705af9d93e3c0f6e29e93b5e9a40caed8`.
Markdown snapshots are normalized only by removing trailing horizontal whitespace.

Documentation can move ahead of an installed release. Confirm exact flags, defaults and behavior
with the installed command's `--help` and the pinned source used by the project. Refresh deliberately
with `scripts/update-foundry-references.sh`, inspect the documentation diff, and commit it separately
from product behavior.
