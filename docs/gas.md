# Gas feasibility

Gas is an architecture constraint when a transaction's work grows with participants, entries,
claims, lots, storage writes or embedded creation code. Resolve that constraint after the first
correct vertical slice, before building downstream scripts, scenarios or UI around the design.

## Declare the budget

Record the target chain and maximum transaction gas budget in the active product contract
(`SPEC.md` when the workflow creates one). When the target is unspecified, use Ethereum's
[EIP-7825 transaction cap](https://eips.ethereum.org/EIPS/eip-7825) of
`16,777,216` gas and a product budget of `12,000,000` gas. The product budget is deliberate
headroom for estimation differences, composition and future changes; it is not a protocol
constant. Other chains require an evidenced chain-specific cap.

A larger block gas limit does not raise the per-transaction cap. Local Anvil execution can also
accept work the target network rejects, so a successful local transaction is not sufficient proof.

## Early feasibility gate

For every scalable public path:

1. Name its caller, incentive, unit of work and maximum supported bound.
2. Implement the smallest correct production-path slice.
3. Measure the maximum bound immediately, including its worst fresh-storage case.
4. Keep a focused test that fails above the declared product budget.
5. If the path misses budget, split it before expanding the product surface.

Resumable work needs a persistent cursor, a hard per-call step limit, monotonic progress, safe repeat
calls, and a terminal postcondition. Test one-step progress, the documented default, the hard
maximum, full completion across calls, and interruption between calls. The caller and incentive to
finish the work must be explicit; nothing onchain advances automatically.

Measure the production owner rather than a duplicate helper or mock. A focused Foundry test can
measure the call directly:

```solidity
uint256 gasBefore = gasleft();
target.process(MAX_SUPPORTED_BOUND);
uint256 gasUsed = gasBefore - gasleft();
assertLt(gasUsed, MAX_TRANSACTION_BUDGET);
```

Use `forge test --gas-report` or a focused gas snapshot to inspect regressions, then simulate the
actual transaction boundary during deployment preparation. The local Foundry routing index is
`references/foundry/README.md`; its gas snapshot is `references/foundry/gas-tracking.md`.

## Measure the deployment graph

When a factory or coordinator embeds creation code, measure the long-lived deployer's runtime and
initcode after the first complete atomic deployment slice. Run `forge build --sizes` and the focused
launch test before building scripts, scenarios or UI around that graph.

If the graph exceeds EIP-170 or EIP-3860, reshape it before expanding downstream. Constructor-only
helper deployers remain narrowly authorized, preserve atomic rollback and reject direct outsider
use. The deployment graph is feasible when every deployable artifact fits its size limit and the
real launch path proves both success and full rollback.

`LooongMarketCoordinatorTest.test_launchFitsTransactionBudgetAndUnexpectedAddressRollsBack` owns
the LOOONG launch gate. One launch is constant work: one token deployment, one pool registration and
initialization, and one founding-liquidity modification. The test enforces the default 12,000,000
gas product budget and proves that an expected-token mismatch leaves no token code behind.

## Keep the limits separate

- **Transaction gas:** whether one call can execute under the target chain's cap.
- **Runtime and initcode size:** EIP-170 and EIP-3860 deployability, checked with
  `forge build --sizes`.
- **Callback gas:** the external protocol's callback allowance, such as a VRF callback limit.
- **Fee cost:** gas price multiplied by gas used; consult current network data only during cost or
  deployment planning.

The [ETHSkills gas guide](https://ethskills.com/gas/SKILL.md) is useful for current fee economics and
mainnet/L2 comparisons. Its market numbers are time-sensitive and do not replace the declared
maximum-transaction budget or the maximum-bound test.

The gate is complete when every scalable public path has a checkable bound, its maximum-bound
production proof fits the declared budget, and any resumable path proves progress and completion
without an unbounded call.
