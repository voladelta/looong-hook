# Companion ERC-20 and NFT

Delete unused seed contracts. When a companion is required, extend the pinned OpenZeppelin base and
keep custom behavior narrow.

## ERC-20

Choose supply once: fixed constructor mint, bounded emission, or explicit mint authority. Avoid
combining several policies. Specify recipient, cap, burn behavior, transfer hooks and recovery. Test
total supply, zero-address boundaries and every custom authority; OpenZeppelin's ordinary transfer
behavior does not need to be retested.

`src/tokens/StarterToken.sol` demonstrates an immutable fixed supply with no owner or later mint.

## ERC-721

Choose who mints, how token IDs advance, whether metadata can change and whether transfers affect
hook accounting. If ownership represents a claim, test transfer, burn and recovery together with
the hook liability.

`src/tokens/StarterNft.sol` demonstrates one immutable minter and sequential IDs. Replace its policy
when the product requires permissionless minting, capped issuance, signatures or hook-only minting.

Pinned bases live under `vendor/openzeppelin-contracts/contracts/token/`.

The companion surface is complete when supply, authority, metadata, transfer, burn, claim, and
recovery behavior are either proved through the product path or explicitly out of scope, and unused
seed contracts and tests are removed.
