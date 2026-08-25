// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {LooongHook} from "../src/LooongHook.sol";
import {LooongLaunchV1} from "../src/LooongLaunchV1.sol";

/// @notice Deploys only from a reviewed network manifest; the shell wrapper owns broadcast authority.
contract TestnetDeployScript is Script {
    error InvalidManifest();

    function run() external {
        string memory manifestPath = vm.envString("DEPLOYMENT_MANIFEST");
        string memory json = vm.readFile(manifestPath);
        uint256 chainId = vm.parseJsonUint(json, ".chainId");
        IPoolManager manager = IPoolManager(vm.parseJsonAddress(json, ".contracts.poolManager"));
        IERC20 looong = IERC20(vm.parseJsonAddress(json, ".contracts.looong"));
        IERC20 weth = IERC20(vm.parseJsonAddress(json, ".contracts.weth"));
        address beneficiary = vm.parseJsonAddress(json, ".feeBeneficiary");
        bytes32 salt = vm.parseJsonBytes32(json, ".launch.salt");
        uint160 sqrtPriceX96 = uint160(vm.parseJsonUint(json, ".launch.sqrtPriceX96"));
        uint128 liquidity = uint128(vm.parseJsonUint(json, ".launch.liquidity"));
        uint256 looongMaximum = vm.parseJsonUint(json, ".launch.looongAmountMaximum");
        uint256 wethMaximum = vm.parseJsonUint(json, ".launch.wethAmountMaximum");
        if (
            chainId != block.chainid || address(manager) == address(0) || address(looong) == address(0)
                || address(weth) == address(0) || address(looong) == address(weth) || beneficiary == address(0)
                || sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE || liquidity == 0
                || looongMaximum == 0 || wethMaximum == 0 || address(manager).code.length == 0
                || address(looong).code.length == 0 || address(weth).code.length == 0
        ) revert InvalidManifest();

        vm.startBroadcast();
        LooongLaunchV1 launcher = new LooongLaunchV1(manager, looong, weth, beneficiary);
        looong.approve(address(launcher), looongMaximum);
        weth.approve(address(launcher), wethMaximum);
        (LooongHook hook,,) = launcher.launch(salt, sqrtPriceX96, liquidity, looongMaximum, wethMaximum);
        vm.stopBroadcast();

        require(address(hook) == launcher.factory().computeAddress(salt), "hook address mismatch");
        require(hook.registered() && hook.initialized(), "pool launch incomplete");
        require(address(launcher.router().hook()) == address(hook), "router binding mismatch");
    }
}
