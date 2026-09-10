# Viem dapp integration

The dapp consumes one generated deployment manifest rather than duplicating addresses in source.
`ui/public/deployment.example.json` documents the browser schema;
`deployments/sepolia.example.json` shows testnet inputs. Deployment writes the ignored
`ui/public/deployment.json`, and devnet shutdown removes it so verification remains clean.

## Boundary

- Verify the wallet chain before reads, simulations or writes.
- Read contract addresses and pool parameters from the manifest.
- Parse and format token amounts with each token's decimals; validate address input and render
  addresses in a copyable, explorer-linked form.
- Use the product's intended router. Universal Router flows bind Permit2 approvals, deadlines,
  recipients and hook data explicitly.
- Treat emitted events as indexing hints; read authoritative balances and claim state from contracts.

The market picker stores subject-address hints and the selected subject under the chain, root and
coordinator identity. Reloading or selecting a hint rechecks the RPC chain, coordinator/root binding,
router PoolKey, live registration and decimals. A failed check leaves an actionable error. Position
actions compare the authoritative `positionPools(positionId)` with the selected market before
simulation. Launch confirmation checks the configured coordinator's receipt event and revalidates
the market before saving it.

## Transaction flow

Model each write as one serialized state machine: connect, switch chain, approve, execute, then
confirm. Present only the next valid action. Each action owns its pending state and disables its
trigger immediately. Rejection or failure returns to an actionable state; confirmation advances
only after authoritative state has refreshed.

Before requesting a signature, simulate the production entry point and present the exact token,
native value and slippage effects. After submission, poll for the receipt, refetch authoritative
state and derive success from receipt status plus product postconditions. Translate wallet, RPC and
decoded contract failures into an actionable message while retaining diagnostic detail.

Treat RPC reads as fallible: expose unavailable or stale state, bound receipt polling and retry
idempotent reads through a deliberate fallback. A transaction hash is progress, not completion.

The launch form calls `LooongMarketCoordinatorV1.openTokenMarket` directly. It binds the connected
wallet as both declared creator and initial fee beneficiary, generates fresh creator salt entropy,
and selects the emitted subject and PoolId only after the launch receipt succeeds. Subsequent buys,
sells, rebates and reward reads carry that selected market identity explicitly; the shared root does
not infer a user market from global state.

## Prove the render

After typecheck and production build, serve the configured application in a real browser at desktop
and the minimum supported width. Confirm that the root mounted, inspect uncaught console errors,
check horizontal overflow, follow the keyboard order and exercise at least one production read and
simulated write. Static compilation is not browser proof.

Render proof is complete when both viewports show the final interface, interactive controls remain
reachable with visible focus, the console has no uncaught application error and the exercised
action reaches its expected pre-signature state.

`ui/` is deliberately small: wallet connection, manifest loading and status display. The product
agent adds hook-specific reads and actions after contract interfaces stabilize. Keep private keys
out of the browser and repository.

The dapp boundary is complete when every supported write uses its production entry point, routed
swaps use the intended router, the transaction state machine exposes no conflicting actions,
simulation and wallet chain checks precede approval, receipt status and product postconditions
determine success, and no address or pool parameter is duplicated outside the manifest.

Startup has explicit loading, ready and error states. A failed manifest or RPC read disables
actions and offers a retry. Wallet account, chain and disconnect events invalidate account-specific
views. Each prepared write retains the provider and account that created its wallet client and
rechecks both before submission. Closed positions are recognized before their cleared pool mapping
is inspected; market changes clear the position ID, and claims refresh wallet/protocol state.

## Browser regression gate

`ui/browser.test.mjs` drives the production handlers against a fresh localhost deployment. It uses
Anvil's unlocked disposable accounts, snapshots each test and restores the chain afterward. Run it
with an existing Playwright and Chromium installation; Node must resolve `playwright` through its
normal module lookup or `NODE_PATH`.

```sh
./scripts/devnet-up.sh
./scripts/devnet-deploy.sh
bun run ui:build
bun run vite preview ui --host 127.0.0.1 --port 4173 --strictPort
```

In another terminal, run `bun run test:browser`. `BROWSER_APP_URL` overrides the default
`http://127.0.0.1:4173`. The suite covers desktop and 320px renders, keyboard focus, startup recovery,
full closures, claims with unrelated inspector inputs, market changes, wallet identity changes,
provider replacement during a pending read, wallet rejection and a failed production simulation.
Stop the preview server and run `./scripts/devnet-down.sh` after the suite finishes.
