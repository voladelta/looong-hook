# Hookr integration

LOOONG is a Hookr launch mode, not a pre-existing token. One chain installation owns a shared
`LooongHook`, `LooongRouter`, and `LooongMarketCoordinatorV1`. Each launch creates a new subject
token and a new token/WETH `PoolId` under that root.

## Launch transaction

Hookr prepares `LooongMarketCoordinatorV1.LaunchArgs`, calls `previewTokenAddress`, and asks the
connected creator wallet to call:

```solidity
openTokenMarket(args, predictedToken)
```

The coordinator requires `args.expectedCreator == msg.sender`, derives the CREATE2 salt from that
creator and the caller-provided deployment salt, requires the nonzero predicted address before
committing the market, and bounds every metadata field by its documented UTF-8 byte limit. The
transaction then:

1. creates the fixed-supply token;
2. registers its token/WETH pool with the shared root;
3. initializes the pool at the exact usable tick;
4. deposits the complete available supply into a one-sided selling band; and
5. emits `LooongMarketOpened(subject, poolId, creator, ...)`.

Hookr should persist both `subject` and `poolId` from the confirmed event. Every later router call
supplies `subject`; every hook accounting read supplies `poolId`.

## Hookr V6 boundary

At Hookr commit `aa5c93b32c22b2f3cf5742fd2c314822406d428f`, a “dedicated root” means another
byte-identical Hookr modular root. It does not admit an arbitrary LOOONG hook through the existing
market coordinator. The V2 partner registry also binds voucher consumption to its configured
coordinator, so a LOOONG launch must not pretend to be an existing modular-root launch.

Hookr therefore needs a LOOONG launch option that targets this coordinator and consumes this event
shape. Partner voucher and revenue-vault support, if required for production, needs an explicitly
registered LOOONG coordinator/profile in Hookr rather than reusing authorization issued for the
modular coordinator. The referenced V6 handoff is marked as an integration reference rather than a
production activation, so no address from it is used as an automatic runtime fallback here.

The dapp in `ui/` is the executable reference for preparing, simulating, submitting, confirming, and
then selecting a newly launched LOOONG market.
