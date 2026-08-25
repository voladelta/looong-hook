// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";

import {StarterHook} from "../src/StarterHook.sol";

/// @notice Mines the permission-bearing address and deploys the project hook.
contract DeployHookScript is BaseScript {
    function run() public {
        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(poolManager);
        address hookAddress;
        bytes32 salt;
        if (vm.envExists("V4HOOK_HOOK_SALT")) {
            salt = vm.envBytes32("V4HOOK_HOOK_SALT");
            hookAddress = vm.envAddress("V4HOOK_PREDICTED_ADDRESS");
        } else {
            // Standalone Foundry usage keeps the official template's built-in miner.
            (hookAddress, salt) =
                HookMiner.find(CREATE2_FACTORY, flags, type(StarterHook).creationCode, constructorArgs);
        }

        // Deploy the hook using CREATE2
        vm.startBroadcast();
        StarterHook hook = new StarterHook{salt: salt}(poolManager);
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployHookScript: Hook Address Mismatch");
    }
}
