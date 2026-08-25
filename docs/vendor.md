# Pinned dependency lane

Read this document when an owned import leads into `vendor/`, provenance must be checked, or a task
explicitly requires a dependency update. Exact upstream repositories and immutable revisions live
in `vendor.lock.json`.

## Search boundary

Treat `vendor/` as read-only implementation source. Start from the owned import, search its tree for
the exact symbol, read the minimum closure needed to establish behavior, and stop there. Enter
Permit2 or Solmate only by following an exact transitive import.

| Tree | What it owns | Useful entry points | Why it is present |
| --- | --- | --- | --- |
| `v4-core` | PoolManager, hook interfaces, pool types, delta and settlement rules | `src/PoolManager.sol`, `src/interfaces/IHooks.sol`, `src/libraries/Hooks.sol`, `src/types/` | Protocol implementation and real callback semantics |
| `v4-periphery` | BaseHook, PositionManager, routers, actions and hook address mining | `src/utils/BaseHook.sol`, `src/utils/HookMiner.sol`, `src/PositionManager.sol`, `src/libraries/Actions.sol` | Production hook base and canonical integration surfaces |
| `openzeppelin-contracts` | ERC-20, ERC-721 and audited utility/security bases | `contracts/token/`, then the exact imported utility | Companion token/NFT implementation |
| `forge-std` | Foundry test, script, cheatcode and invariant utilities | `src/Test.sol`, `src/Script.sol`, `src/StdInvariant.sol` | Local tests and deployment scripts |
| `permit2` | Permit2 interfaces and implementation used by v4 periphery | follow the exact import from `v4-periphery` | Transitive PositionManager/router approval dependency |
| `solmate` | Lightweight token and utility contracts used transitively by pinned Uniswap code | follow the exact import from `v4-core`, `v4-periphery` or a fixture | Transitive compile/test dependency |

`test/utils/v4hook-testkit/` is project test infrastructure rather than a general dependency tree.
Its Solidity sources expose the real pinned PoolManager/PositionManager fixture. Files under
`test/utils/v4hook-testkit/artifacts/` contain deployment bytecode and are not source-reading targets.

Source inspection is complete when the owned import, defining symbol, and relevant pinned behavior
are identified without widening into unrelated vendor trees.

## Updating a dependency

Update only when the task requires it. Change the dependency, `vendor.lock.json`, tree-specific
provenance, affected imports, and proofs as one reviewed slice. Inspect the vendored diff for
unexpected files, then run formatting, build, real PoolManager integration tests, and the full gate.
Keep independent upgrades in separate changes.

An update is complete when provenance names an immutable revision, every consumer compiles against
the new tree, real-boundary behavior is green, and the diff contains only the intended dependency
closure.
