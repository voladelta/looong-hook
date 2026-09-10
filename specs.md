# looong-hook specification

## 1. Purpose and status

`looong-hook` is Hookr's shared Uniswap v4 root for tokens launched in LOOONG mode. Every launch creates a distinct
fixed-supply subject token and token/WETH pool while reusing one root and authenticated router. Purchases made through
that router become pool-scoped, custodied, non-transferable positions with verifiable WETH cost basis. Position holders
can sell from custody, withdraw their tokens, earn rewards after 30 days, and recover most or all of the hook's
sell-side fee when their exit satisfies the rebate rules.

This document specifies the behavior of the reference implementation. It is not an audit, deployment claim, or
production-readiness statement.

## 2. Naming

- Product and repository name: `looong-hook`
- Hook behavior and launch-mode name: `LOOONG`
- Base asset: the subject token created by each launch
- Quote asset: `WETH`
- Contract names: `LooongHook`, `LooongRouter`, `LooongHookFactory`, `LooongTokenV1`, and
  `LooongMarketCoordinatorV1`

All user-facing copy, metadata, deployment manifests, and contract adaptations must use these names.

## 3. Fixed parameters

| Parameter | Value |
| --- | ---: |
| Pool | launched subject token/WETH |
| Subject supply | 1,000,000,000 tokens |
| Uniswap v4 LP fee | 3,000 pips (0.30%) |
| Tick spacing | 60 |
| Initial liquidity range | One-sided 207,000-tick selling band anchored at the opening tick |
| Token name | 1–64 UTF-8 bytes |
| Token symbol | 1–16 UTF-8 bytes |
| Token tagline | 0–160 UTF-8 bytes |
| Token logo URI | 0–256 UTF-8 bytes |
| Hook buy fee | 10 bps |
| Hook sell fee | 300 bps |
| Base protocol fee stream | 10 bps of gross WETH volume |
| Sell rebate/reward component | 290 bps of gross WETH volume |
| Position maturity | 30 days |
| Maximum early-profit share | 30% of eligible profit |
| Fee-rate denominator | 1,000,000 hundredths of a basis point |
| Reward accounting precision | `1e27` |
| Minimum nonzero gross WETH amount | 1,000 smallest WETH units |

Uniswap LP fees are independent of the hook fees and are excluded from the calculations in this document.

## 4. Contract responsibilities

### 4.1 Hook

The hook owns every registered pool configuration, validates swap callbacks, charges WETH-denominated fees, custodies
subject tokens for verified positions, records cost basis, accounts for rebates and rewards, and enforces
asset/liability conservation independently by PoolId.

One shared hook instance binds to one PoolManager, registrar, trusted router, WETH quote asset, fee schedule and maturity
period. Each PoolId permanently binds one distinct subject token and fee beneficiary. Pool-scoped position, remainder,
rebate, share and reward state must never cross PoolIds.

### 4.2 Router

The router is the only component allowed to stage verified intents. It supports:

- exact-input buys funded with WETH; and
- exact-input sells funded from a position's custodied `LOOONG`.

The router must bind the caller as position owner, pass a price limit, enforce a minimum output and deadline, settle
the PoolManager deltas, and never allow one wallet's allowance or position to be spent by another wallet.

### 4.3 Factory

The factory deploys the hook with CREATE2 and accepts only addresses whose low bits encode these five permissions:

- `beforeInitialize`
- `beforeSwap`
- `afterSwap`
- `beforeSwapReturnDelta`
- `afterSwapReturnDelta`

All other hook permissions must be disabled.

### 4.4 Token and market coordinator

The shared router and permission-mined root are installed once per chain. Each user-callable coordinator launch must:

1. bind `msg.sender` as the token creator;
2. deploy a fixed-supply subject token deterministically;
3. register and initialize its exact token/WETH pool under the shared root;
4. place the complete supply in a one-sided founding band without requiring creator WETH;
5. retain the liquidity position permanently in the coordinator; and
6. send liquidity-rounding residue to the dead address without reducing the fixed total supply.

When the subject is currency0, the band runs from the opening tick to opening tick + 207,000.
When the subject is currency1, it runs from opening tick - 207,000 to the opening tick. Both ends must
remain within usable ticks `-887220` and `887220`. The coordinator holds no remaining subject tokens
after launch and exposes no path to collect the founding position's LP fees.

The caller must equal the declared creator. A repeated creator salt must revert atomically. The coordinator exposes no
liquidity removal, rescue, ownership, upgrade, or arbitrary-call path.

## 5. Pool admission and token assumptions

The hook must reject callbacks unless all of the following are true:

- the PoolId has been registered with its immutable subject token and beneficiary;
- the callback originates from the immutable PoolManager;
- the supplied `PoolKey` hashes to that registered PoolId;
- the hook address in the key is the current hook;
- currencies are distinct and correctly sorted;
- one currency is the immutable WETH quote asset;
- the other currency is the PoolId's registered subject token;
- tick spacing is within Uniswap v4 bounds; and
- the LP fee is valid and no greater than 999,998 pips, preserving exact-output compatibility.

Coordinator-created subject tokens are standard fixed-supply ERC-20s without rebasing or transfer fees. WETH is the
only supported quote asset; native ETH is not supported.

## 6. Swap modes

### 6.1 Verified routes

Verified routes are exact-input only.

Before a swap, the trusted router stages a one-shot intent committing to:

- registered pool id;
- owner;
- buy or sell kind;
- position id;
- swap direction;
- exact input amount;
- square-root price limit;
- minimum output;
- deadline; and
- owner nonce.

The hook data contains only an intent-domain magic value and the resulting intent id. During `beforeSwap`, the hook
authenticates the router, validates the complete commitment, verifies the deadline and position ownership, and marks
the intent claimed. During `afterSwap`, it enforces output and fill constraints, applies position accounting, and
deletes the intent. A revert rolls back the entire transition, and a consumed intent cannot be replayed.

Verified buy flow:

1. The owner supplies exact-input WETH through the router.
2. The hook charges the 10 bps buy fee.
3. Actual subject-token output is diverted into hook custody.
4. A new position is created for the owner.
5. The position's initial WETH basis is the executed gross WETH input, including the hook fee.

Verified sell flow:

1. The router identifies an owner-controlled position and exact `LOOONG` amount.
2. The hook prepays that exact base-token debt from custody.
3. The executed gross WETH output is charged the 300 bps sell fee.
4. Basis, rebate, early-profit share, reward shares, and remaining position balances are updated atomically.
5. Net WETH output is sent directly to the owner.

Partial fills that would make the verified input or output accounting ambiguous must revert.

### 6.2 Ordinary router compatibility

Empty hook data preserves ordinary Uniswap v4 routing across all four combinations of direction and exact-input or
exact-output. These swaps pay the same hook rates but do not create or consume verified positions.

An ordinary sell sends the entire 290 bps sell component to the mature-holder reward pool. Ordinary buys have no
rebate/reward component because their total hook fee is the 10 bps base protocol stream.

### 6.3 Exact-output accounting

For exact output, the hook must determine a gross WETH amount such that:

```text
gross WETH - base protocol fee - rebate/reward component = requested net WETH
```

A dedicated exact-output hook-data domain may supply a gross-WETH witness. The hook validates the witness against the
current lifetime fee remainders before changing either fee stream. A stale or forged witness must revert, and witness
data must be rejected on exact-input swaps.

With empty hook data, the hook may use the bounded onchain compatibility solver: start from the closed-form gross-up,
search at most 17 consecutive candidates, and revert when no exact integer solution exists.

### 6.4 Executed-volume rule

Fees are based on actual executed gross WETH volume, not merely the requested amount.

- If WETH is the specified currency, the charge is computed before the core swap and the executed WETH delta must
  match the expected pool amount exactly.
- If WETH is the unspecified currency, the charge is computed from the executed `BalanceDelta` after the core swap.
- Any nonzero gross amount below 1,000 smallest WETH units reverts atomically.

## 7. Positions and cost basis

Each position records:

- immutable owner;
- opening timestamp;
- reward-active flag;
- initial, remaining, sold, and withdrawn `LOOONG` amounts;
- initial, remaining, sold, and withdrawn WETH basis; and
- a carried numerator remainder for early-profit calculations.

Positions are internal records, not ERC-721 tokens, and cannot be transferred.

For a partial sell or withdrawal, basis is allocated as:

```text
allocated basis = floor(remaining basis * token amount / remaining tokens)
```

A full close consumes all remaining basis exactly. The following conservation rules must always hold for every live
position:

```text
initial tokens = remaining tokens + sold tokens + withdrawn tokens
initial basis  = remaining basis + sold basis + withdrawn basis
```

A position with no remaining tokens is deleted, but owner-level pending rewards remain claimable.

## 8. Sell rebate and early-profit share

The 300 bps sell fee comprises the 10 bps base protocol stream and a 290 bps rebate/reward component.

For a verified position sell:

```text
eligible profit = max(gross WETH - base protocol fee - allocated basis, 0)
time remaining  = max(opened at + 30 days - current time, 0)
raw share       = floor(
  (eligible profit * 3,000 * time remaining + carried remainder)
  / (10,000 * 30 days)
)
early-profit share = min(raw share, 290 bps component)
seller rebate      = 290 bps component - early-profit share
```

The early-profit share decays linearly from at most 30% of eligible profit at opening to zero at 30 days. It is always
capped by the actual 290 bps component charged on that sell.

The early-profit share is distributed only when other mature shares exist. The seller's own mature shares are
excluded from that distribution. The seller receives the full 290 bps component as a rebate when any of these apply:

- the position has matured;
- the exit has no eligible profit; or
- no other mature holder is eligible to receive rewards.

Rebates accrue as WETH liabilities keyed by PoolId and seller and are claimed separately from swap output.

## 9. Maturity and rewards

After a position has been open for 30 days, anyone may activate it for rewards. Activation is idempotent. It
checkpoints the owner's existing rewards and adds the position's remaining `LOOONG` amount to the owner's eligible
shares.

Selling or withdrawing from an active position must checkpoint the owner first and remove the corresponding shares.
Reward distribution uses a cumulative per-share index with `1e27` precision. Sub-WETH-unit credit and division dust
remain explicit liabilities and must not be discarded.

When rewards from a verified sell are distributed, all shares owned by the seller are excluded. When an ordinary
sell is distributed, all active shares participate. If no eligible shares exist, the scaled amount remains as reward
dust until shares become active and the amount can be indexed.

## 10. Withdrawals and claims

An owner may withdraw any nonzero amount up to a position's remaining `LOOONG`. Withdrawal:

- charges no hook sell fee;
- transfers the requested `LOOONG` from custody to the owner;
- proportionally destroys the associated basis;
- removes active reward shares; and
- deletes a fully withdrawn position.

Claims follow checks-effects-interactions and are protected from reentrancy:

- The immutable base-fee beneficiary may claim accrued base protocol fees to a nonzero recipient.
- Anyone may trigger a seller rebate claim, but WETH must always be sent to the credited seller.
- A reward owner may claim whole-unit WETH rewards to a chosen nonzero recipient; scaled fractional credit remains.

Fee collection is held as PoolManager ERC-6909 WETH claims. Redemption burns the exact claims before taking underlying
WETH for the recipient. A failed redemption must restore the accrued liability by reverting the transaction. Claims
received without a matching protocol fee are surplus: they create no entitlement and cannot make accounted liabilities
unclaimable.

## 11. Required accounting invariants

The implementation must preserve all of the following after every successful external operation:

```text
hook subject balance >= total remaining position tokens in that subject's PoolId

actual PoolManager WETH claims >= accounted WETH claims

accounted WETH claims * 1e27
  = base-fee liability * 1e27
  + total rebate liability * 1e27
  + total scaled reward liability
```

Each fee stream maintains an independent lifetime numerator remainder modulo 1,000,000:

```text
stream fee       = floor((gross WETH * rate + prior remainder) / 1,000,000)
stream remainder =       (gross WETH * rate + prior remainder) % 1,000,000
```

Claims never reset these remainders. Splitting the same accepted gross volume across swaps must not suppress the
cumulative fee entitlement.

Accounted WETH claims are claims minted by the hook for collected fees, less claims burned for redemptions.
The liabilities in the equality are summed across all PoolIds. Unsolicited ERC-6909 transfers or mints to
the hook create surplus backing, leave liabilities unchanged, and must not block swaps or claims in any
pool. Surplus has no redemption or rescue path. Donations must not create fees, rewards, or positions.
Accidental token transfers must not be treated as accounted assets.

## 12. Security and failure requirements

The implementation must reject:

- callbacks from any address other than the immutable PoolManager;
- initialization by anyone other than the registrar/hook launch path;
- a second registration of the same PoolId;
- any unregistered or mismatched pool key;
- intent staging by an untrusted router;
- expired, malformed, mismatched, replayed, or wrong-domain intents;
- a position sell or withdrawal by a non-owner;
- a sell or withdrawal exceeding the position balance;
- unsupported exact-output use on verified routes;
- stale or invalid exact-output witnesses;
- quote-specified partial fills;
- zero-value state-changing requests where no meaningful action exists;
- claim redirection or double claims;
- unsupported base-token transfer behavior; and
- any operation that breaks base custody or WETH claim conservation.

Reentrancy protection is required around position withdrawals, claims, pool registration, swap callbacks, and each
atomic launch. Unlock callbacks must bind their exact expected payload and lifecycle state.

## 13. Deliberate exclusions

The reference design has no:

- administrator or mutable owner;
- upgrade mechanism;
- mutable fee, maturity, router, pool, or recipient configuration;
- pause, blacklist, allowlist, or transfer control;
- project treasury withdrawal;
- ERC-721 representation of positions;
- native ETH quote support;
- arbitrary token implementations, post-launch minting, mutable metadata, or creator supply allocations;
- same-pool swap initiated by the hook;
- rescue, sweep, or arbitrary external call; or
- recovery path for accidentally transferred unsupported assets.

Wallet sybil identities remain possible. MEV on ordinary swaps, return-delta sign correctness, custody assumptions,
composite rounding, router compatibility, deployment/runtime matching, and operational monitoring require independent
review before production use.

## 14. Acceptance criteria

At minimum, the executable test suite must prove:

- exact frozen parameters and callback permission bits;
- atomic launches of multiple subject pools under one root, with permanently locked one-sided founding liquidity;
- verified buys create custodied positions with executed gross WETH basis;
- partial and full sells conserve token amounts and basis;
- free withdrawals return `LOOONG` and destroy proportional basis;
- fresh profitable exits share the bounded amount with other mature holders;
- mature, loss-making, and no-other-holder exits receive the full rebate;
- a seller cannot earn their own early-profit share;
- ordinary sells distribute the full 290 bps component;
- all four ordinary swap quadrants work in either currency ordering;
- actual executed WETH volume drives fees;
- fee remainders survive swaps and claims;
- current exact-output witnesses work while stale, forged, and exact-input witnesses fail;
- intent mutation, replay, expiry, wrong-router, wrong-pool, and wrong-manager calls fail;
- claims cannot be redirected or repeated;
- donations do not affect fees, rewards, or positions or prevent subsequent swaps and claims;
- selecting an earlier market after another launch or browser reload preserves authoritative pool identity; and
- stateful sequences preserve token, basis, custody, and WETH-liability conservation.

Independent static analysis, mainnet-fork lifecycle testing, gas profiling, economic review, security review, deployed
bytecode matching, source verification, and monitoring remain release gates.
