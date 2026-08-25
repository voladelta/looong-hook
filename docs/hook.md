# Hook design

Start from the product's fund and identity flow, then select callbacks. An enabled callback without
a production use is additional attack surface and an address-mining constraint.

## Design order

1. Define supported pool keys, currencies, fee mode and token ordering.
2. Define the intended router and the boundary that authenticates payer, recipient and beneficiary.
3. Map exact-input and exact-output accounting in both directions.
4. Define which contract owns funds, claims, remainders and recovery.
5. Select the minimum callbacks and return-delta flags needed by that model.
6. Keep `getHookPermissions`, mined address flags, deployment script and tests identical.

Use the inherited external callbacks from the pinned BaseHook. Implement internal `_before*` and
`_after*` methods; retain its PoolManager-only check. Callback `sender` is the immediate router or
locker, not automatically the end user.

Design is frozen when every supported value flow has a named payer, recipient, settlement path,
delta owner, and recovery policy, and the hook enables only the callbacks those flows require.

## Pinned source anchors

- `vendor/v4-periphery/src/utils/BaseHook.sol`
- `vendor/v4-core/src/interfaces/IHooks.sol`
- `vendor/v4-core/src/libraries/Hooks.sol`
- `vendor/v4-core/src/types/BeforeSwapDelta.sol`
- `vendor/v4-core/src/types/BalanceDelta.sol`
- `vendor/v4-periphery/src/utils/HookMiner.sol`

Read only the symbols used by the chosen design. The pinned code is the implementation authority;
external documentation is for a specifically missing current network fact, not startup research.

## Native/token swap map

For a canonical pool with native currency as `currency0` and the companion token as `currency1`,
freeze this matrix before implementing fee deltas:

| User operation | `zeroForOne` | `amountSpecified` | Native lane |
| --- | --- | --- | --- |
| Buy, exact input | `true` | negative | specified |
| Buy, exact output | `true` | positive | unspecified |
| Sell, exact input | `false` | negative | unspecified |
| Sell, exact output | `false` | positive | specified |

Positive hook deltas mean the hook takes currency; PoolManager subtracts them from the router's
delta. Prove the four rows against observed deltas and balances rather than duplicating this table
inside production math.

The testkit's `PoolSwapTest` is a fixture, not a production identity boundary. A hook that attributes
buyers or beneficiaries needs an authenticated router/settlement path that captures payer and
recipient before unlock and takes output directly to the recipient. Refund only value supplied by
the current call; a router's pre-existing or forced native balance belongs to neither caller.
`src/router/AuthenticatedNativeTokenRouter.sol` is the replaceable single-pool seed for that boundary;
its integration test proves all four quadrants, spoof rejection, partial-fill rollback and forced
native isolation through the real PoolManager.

Swap accounting is complete when an independent test oracle proves all four supported rows against
observed deltas, balances, liabilities, remainders, and rollback behavior.

## Deployment footprint

Run `forge build --sizes` after the first compiling vertical slice. A runtime factory or router that
references `type(Hook).creationCode` embeds that creation code and can exceed EIP-170 even when the
hook itself fits. Keep large CREATE2 launch code in a constructor-only factory or a separate
deployer, while the long-lived router remains small. Re-run the exact launch rollback proof after
changing this boundary.

Callback, launch or lifecycle work that grows with participants or storage must also pass the
maximum-transaction gate in `docs/gas.md`; contract size alone does not establish executability.

Deployment proof is complete when the hook and every long-lived launcher fit their applicable size
limits and the exact launch path proves atomic rollback.
