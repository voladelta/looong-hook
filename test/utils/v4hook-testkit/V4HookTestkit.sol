// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {V4Bindings} from "./V4Bindings.sol";
import {Permit2Deployer} from "./artifacts/Permit2.sol";
import {V4PoolManagerDeployer} from "./artifacts/V4PoolManager.sol";
import {V4PositionManagerDeployer} from "./artifacts/V4PositionManager.sol";

/// @notice Local-only Uniswap v4 fixture deployment and test helpers.
abstract contract V4HookTestkit is V4Bindings {
    error V4HookTestkitLocalOnly(uint256 chainId);

    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    PoolSwapTest internal poolSwapRouter;

    function deployV4Testkit() internal {
        if (block.chainid != 31337) revert V4HookTestkitLocalOnly(block.chainid);

        if (CANONICAL_PERMIT2.code.length == 0) {
            _etch(CANONICAL_PERMIT2, Permit2Deployer.deploy().code);
        }

        address manager = V4PoolManagerDeployer.deploy(address(0x4444));
        address positions =
            V4PositionManagerDeployer.deploy(manager, CANONICAL_PERMIT2, 300_000, address(0), address(0));
        _bindV4(CANONICAL_PERMIT2, manager, positions);
        poolSwapRouter = new PoolSwapTest(poolManager);
    }

    function deployToken() internal returns (MockERC20 token) {
        token = new MockERC20("Test Token", "TEST", 18);
        token.mint(address(this), 10_000_000 ether);

        token.approve(address(poolSwapRouter), type(uint256).max);
        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token), address(poolManager), type(uint160).max, type(uint48).max);
    }

    function deployCurrencyPair() internal virtual returns (Currency currency0, Currency currency1) {
        MockERC20 token0 = deployToken();
        MockERC20 token1 = deployToken();

        if (token0 > token1) (token0, token1) = (token1, token0);

        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));
    }

    function _etch(address target, bytes memory bytecode) internal virtual;
}
