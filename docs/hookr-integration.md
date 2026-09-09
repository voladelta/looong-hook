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

Hookr should check receipt success, decode the event only from the configured coordinator, and
verify its subject and PoolId against the root's registered market. Persist the pair under the
chain and installation identity. Every later router call supplies `subject`; every hook accounting
read supplies `poolId`. Resolve `positionPools(positionId)` before preparing a position sell.

## Pinned Hookr boundary

The current reference is the supplied Hookr checkout at
[`876000c9ef5f1c2c21a41d4c9dabf417d990503b`](https://github.com/Hookr-fun/hookr-modular-hooks/tree/876000c9ef5f1c2c21a41d4c9dabf417d990503b).
Its `SOURCE_MANIFEST.json` identifies exported source commit
`8db7fc940938f811f508ba9cb0c8f2d3f24c9a25`. This replaces the historical `aa5c93b` comparison;
the earlier V6 SDK and handoff are absent from this export.

`HookrMarketCoordinatorV5` removes partner vouchers, relayers and per-pool revenue vaults. Its
modular launch path requires native mechanics and uses dynamic LP fees. `HookrStackRegistryV1`
binds its coordinator once, validates kernel wiring to the registry and coordinator, and accepts
dynamic-fee pool keys. LOOONG uses a separate registrar and a fixed 3,000-pip pool fee, so its root
does not satisfy that modular registration path.

Hookr therefore needs a dedicated frontend launch option, event indexing and routing support for
the LOOONG coordinator and root. That external integration is a prerequisite, not something this
repository activates. Selecting a LOOONG `feeBeneficiary` assigns the complete base-fee stream to
that address; it does not implement Hookr's native-mechanics treasury or creator fee splits. Any
required attribution or revenue sharing needs an agreed integration contract. The removed voucher
and vault machinery is not a prerequisite of this pinned V5 export.

No Hookr runtime address, deployment status or external acceptance is inferred from the source
export. Public activation still requires reviewed network manifests and independent security and
economic review.

The dapp in `ui/` is the executable reference for preparing, simulating, submitting, confirming, and
then selecting a newly launched LOOONG market.
