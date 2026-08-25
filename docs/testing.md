# Behavioral proof

Test through the same boundary the real consumer uses. A mock, duplicate helper, or assertion that
reuses production math cannot prove the requested artifact.

## Place the proof

- `test/unit/`: pure math, token/NFT policy, authorization, and isolated lifecycle state.
- `test/integration/`: pinned PoolManager, PositionManager, router, and settlement behavior.
- `test/fuzz/`: arithmetic and state-transition properties over bounded valid domains.
- `test/invariant/`: stateful conservation, solvency, and exact action accounting.
- `test/mocks/`: external services only; PoolManager business behavior stays real.

`test/utils/v4hook-testkit/` deploys the real pinned v4 bytecode locally. Read `PROVENANCE.md` before
changing the fixture, and treat files under its `artifacts/` directory as opaque bytecode.

Prove causality for each requested production behavior: make a reversible perturbation to its
implementation in the requested artifact while preserving the consumer-facing interface. Run the
focused proof through the real consumer; it must go red on the expected behavioral assertion, then
green after the original implementation is restored. If it stays green, trace the consumer path and
repair the proof or remove the bypass before completion.

## Prove swap accounting

When the hook changes swaps, cover exact-input and exact-output in both directions. Assert executed
PoolManager deltas, hook return deltas, payer and recipient balances, liabilities, remainders, and
full rollback.

Compute fees, gross-up, splits, and carried remainders in an independent test oracle. Include values
between documented examples so early integer flooring cannot hide. A nonzero-fee assertion is not
accounting proof.

The swap matrix is complete when every supported quadrant passes through the real router and
PoolManager, and each hostile or partial-fill case rolls back all affected state.

## Account for stateful actions

For every action class, handlers count attempts, successes, exact expected failures, and unexpected
failures. Include each supported exactness/direction mode and each material lifecycle transition.
Assert:

```text
attempts == successes + expected failures + unexpected failures
```

Require every material class to succeed and unexpected failures to remain zero. When liabilities
must be separated from surplus, track forced funds with an independent ghost value.

`test/utils/InvariantActionAccounting.sol` supplies bookkeeping without choosing product actions or
invariants. Its expected-revert classifier requires a nonzero custom-error selector; empty or
mismatched revert data is unexpected. Classify the observed production revert before incrementing
an expected-failure counter.

Stateful proof is complete when every attempted action is classified exactly once, every material
class succeeds, conservation holds after each sequence, and unexpected failures are zero.

## Run the gates

Run the nearest focused proof during development, then `./scripts/check.sh`. Use Bun for the
TypeScript workspace. `SKIP_APP=1 ./scripts/check.sh` is valid only when the task explicitly excludes
the dapp and scenario layer.

A skipped required test or empty filter is a failure. Accept the full gate only when its process
exits zero and prints the final `CHECK_OK`; earlier tool output does not prove later stages ran.

Gas feasibility precedes downstream expansion. For public work that scales with state or inputs,
follow `docs/gas.md` and keep its maximum-bound production-path test in the ordinary suite.

Verification is complete when focused proof and every applicable full-gate stage are green, the
sentinel is present, and the final source has not changed since those commands ran.
