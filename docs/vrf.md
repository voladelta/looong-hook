# Chainlink VRF v2.5 direct funding

This starter supports one opinionated randomness path: native-payment VRF v2.5 direct funding for
infrequent requests. The exact upstream source closure is pinned under `vendor/chainlink-evm/`; read
its `PROVENANCE.md` before changing it.

`src/vrf/DirectFundingVrfConsumer.sol` is a compiling lifecycle reference, not a product-specific
winner selector. Adapt or compose it so the product freezes every outcome-affecting input before the
request.

## Invariants

- The wrapper and confirmation count are constructor-bound.
- Callback gas is 150,000, one word is requested, and native payment is explicit.
- The price is quoted and capped at 0.01 native currency before payment.
- Request IDs bind commitments; fulfillment order has no meaning.
- A commitment cannot retry, cancel, reroll or use block-derived fallback randomness.
- The authenticated callback stores one terminal result and emits; settlement happens later.
- Authenticated unknown, malformed, duplicate or late callbacks return without reverting.
- Seven-day recovery is terminal and late fulfillment cannot reopen the request.
- VRF requests never execute from a PoolManager callback.

Use `test/mocks/MockVrfV2PlusWrapper.sol` only for the external wrapper boundary. Tests must enter
the consumer through the vendored base's authenticated `rawFulfillRandomWords` path.

Network wrapper addresses, supported confirmations and current pricing are deployment inputs. Verify
them against official Chainlink sources only when preparing the named network; they are not local
implementation research.

The randomness branch is complete when every outcome-affecting input is frozen before request,
authenticated fulfillment can only record one terminal result, delayed settlement proves its own
custody rules, and recovery cannot be reopened by a late callback.
