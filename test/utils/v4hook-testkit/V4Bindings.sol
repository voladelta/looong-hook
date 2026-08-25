// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @notice Plan-bound Uniswap v4 dependencies shared by scripts and the local testkit.
abstract contract V4Bindings {
    error V4DependencyHasNoCode(address dependency);

    IPermit2 internal permit2;
    IPoolManager internal poolManager;
    IPositionManager internal positionManager;

    function _bindV4(address permit2Address, address poolManagerAddress, address positionManagerAddress) internal {
        _requireCode(permit2Address);
        _requireCode(poolManagerAddress);
        _requireCode(positionManagerAddress);

        permit2 = IPermit2(permit2Address);
        poolManager = IPoolManager(poolManagerAddress);
        positionManager = IPositionManager(positionManagerAddress);
    }

    function _requireCode(address dependency) private view {
        if (dependency.code.length == 0) revert V4DependencyHasNoCode(dependency);
    }
}
