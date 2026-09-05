# Testnet deployment

Preparation and broadcast are separate authority boundaries.

## Prepare

1. Choose the named testnet and verify PoolManager and WETH addresses from official registries.
2. Record chain ID, creator, addresses, expected token address and expected bytecode in
   `deployments/<network>.json`.
3. Run `./scripts/testnet-dry-run.sh <network>` against a pinned fork block.
4. Exercise each included branch on the fork: shared-root deployment, token creation, pool
   initialization, founding liquidity, all supported swap quadrants and dapp manifest reads.

Preparation is complete when the pinned fork proves every included branch and the handoff names the
user-run command, network, account alias requirement, and remaining authorities.

The script uses the manifest creator as the explicit Foundry broadcaster and derives the router,
factory and coordinator addresses from that account's pinned fork nonce. It rejects a coordinator
prediction that differs from `root.expectedCoordinator`. The broadcast account must resolve to the
same creator, and its nonce must remain unchanged after the final dry run.

## Broadcast

Run `./scripts/testnet-deploy.sh <network> --account <foundry-keystore-name>` only after the user
authorizes broadcast to that network. Scripts may reference the keystore alias but never read,
print, export or request its secret. Confirm receipt status, deployed bytecode, hook permission bits,
constructor bindings, token metadata, `PoolId`, and pool state before publishing the manifest to
`ui/public/deployment.json`.

Broadcast is complete only after every receipt and deployed binding is verified and the published
manifest matches the observed network state.
