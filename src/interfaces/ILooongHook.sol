// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface ILooongHook {
    function INTENT_DOMAIN() external view returns (bytes4);

    function registerPool(PoolKey calldata key) external;

    function stageBuy(
        address owner,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        uint160 sqrtPriceLimitX96,
        uint64 deadline
    ) external returns (bytes32 intentId, uint256 positionId);

    function stageSell(
        address owner,
        uint256 positionId,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        uint160 sqrtPriceLimitX96,
        uint64 deadline
    ) external returns (bytes32 intentId);
}
