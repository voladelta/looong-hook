// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {V4Bindings} from "test/utils/v4hook-testkit/V4Bindings.sol";

/// @notice Shared configuration between scripts
contract BaseScript is Script, V4Bindings {
    address immutable deployerAddress;

    /////////////////////////////////////
    // --- Configure These ---
    /////////////////////////////////////
    IERC20 internal immutable token0;
    IERC20 internal immutable token1;
    IHooks immutable hookContract;
    /////////////////////////////////////

    Currency immutable currency0;
    Currency immutable currency1;

    constructor() {
        token0 = IERC20(vm.envOr("V4HOOK_CURRENCY0", 0x0165878A594ca255338adfa4d48449f69242Eb8F));
        token1 = IERC20(vm.envOr("V4HOOK_CURRENCY1", 0xa513E6E4b8f2a923D98304ec87F64353C4D5C853));
        address configuredHook = vm.envOr("V4HOOK_HOOK_ADDRESS", address(0));
        if (configuredHook == address(0)) {
            configuredHook = vm.envOr("V4HOOK_PREDICTED_ADDRESS", address(0));
        }
        hookContract = IHooks(configuredHook);

        // These addresses are supplied from the verified v4hook deployment plan.
        _bindV4(
            vm.envAddress("V4HOOK_PERMIT2"),
            vm.envAddress("V4HOOK_POOL_MANAGER"),
            vm.envAddress("V4HOOK_POSITION_MANAGER")
        );

        deployerAddress = getDeployer();

        (currency0, currency1) = getCurrencies();

        vm.label(address(permit2), "Permit2");
        vm.label(address(poolManager), "V4PoolManager");
        vm.label(address(positionManager), "V4PositionManager");

        vm.label(address(token0), "Currency0");
        vm.label(address(token1), "Currency1");

        vm.label(address(hookContract), "HookContract");
    }

    function getCurrencies() internal view returns (Currency, Currency) {
        require(address(token0) != address(token1));

        if (token0 < token1) {
            return (Currency.wrap(address(token0)), Currency.wrap(address(token1)));
        } else {
            return (Currency.wrap(address(token1)), Currency.wrap(address(token0)));
        }
    }

    function getDeployer() internal returns (address) {
        address[] memory wallets = vm.getWallets();

        if (wallets.length > 0) {
            return wallets[0];
        } else {
            return msg.sender;
        }
    }
}
