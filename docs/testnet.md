# Testnet deployment

Preparation and broadcast are separate authority boundaries.

## Prepare

1. Choose the named testnet and verify PoolManager, PositionManager, Universal Router, Permit2 and
   Chainlink wrapper addresses from official registries.
2. Record chain ID, addresses and expected bytecode in `deployments/<network>.json`.
3. Run `./scripts/testnet-dry-run.sh <network>` against a pinned fork block.
4. Exercise each included branch on the fork: deployment, pool initialization, liquidity, all
   supported swap quadrants, VRF request wiring, and dapp manifest reads as applicable.

Preparation is complete when the pinned fork proves every included branch and the handoff names the
user-run command, network, account alias requirement, and remaining authorities.

## Broadcast

Run `./scripts/testnet-deploy.sh <network> --account <foundry-keystore-name>` only after the user
authorizes broadcast to that network. Scripts may reference the keystore alias but never read,
print, export or request its secret. Confirm receipt status, deployed bytecode, hook permission bits,
constructor bindings and pool state before publishing the manifest to `ui/public/deployment.json`.

Broadcast is complete only after every receipt and deployed binding is verified and the published
manifest matches the observed network state.
