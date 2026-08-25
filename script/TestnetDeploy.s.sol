// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

/// @notice Product-owned dry-run and testnet broadcast boundary.
/// @dev Replace this seed after the deployment graph and manifest schema stabilize.
contract TestnetDeployScript is Script {
    error TestnetDeployNotImplemented();

    function run() external pure {
        revert TestnetDeployNotImplemented();
    }
}
