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

## LOOONG/WETH swap map

The router derives `zeroForOne` from the sorted `LOOONG` and WETH addresses. Freeze this matrix
before you change fee deltas:

| User operation | Input asset | `amountSpecified` | WETH lane |
| --- | --- | --- | --- |
| Buy, exact input | WETH | negative | specified |
| Buy, exact output | WETH | positive | unspecified |
| Sell, exact input | LOOONG | negative | unspecified |
| Sell, exact output | LOOONG | positive | specified |

Positive hook deltas mean the hook takes currency; PoolManager subtracts them from the router's
delta. Prove the four rows against observed deltas and balances rather than duplicating this table
inside production math.

The testkit's `PoolSwapTest` is a fixture, not a production identity boundary. `src/LooongRouter.sol`
captures the payer, owner, and recipient before unlock. It settles only ERC-20 assets. Native ETH is
not supported. `test/integration/LooongHook.t.sol` proves the four ordinary quadrants, verified owner
binding, partial-fill rollback, and claim conservation through the real PoolManager.

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
