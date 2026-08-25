// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

/// @notice Product-owned devnet bootstrap boundary.
/// @dev Replace this seed with dependency, hook, token, pool and liquidity deployment, then write
///      `.devnet/deployment.json` through Foundry's JSON cheatcodes.
contract DevnetDeployScript is Script {
    error DevnetDeployNotImplemented();

    function run() external pure {
        revert DevnetDeployNotImplemented();
    }
}
