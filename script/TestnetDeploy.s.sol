// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {LooongHookFactory} from "../src/LooongHookFactory.sol";
import {LooongMarketCoordinatorV1} from "../src/LooongMarketCoordinatorV1.sol";
import {LooongRouter} from "../src/LooongRouter.sol";

/// @notice Deploys only from a reviewed network manifest; the shell wrapper owns broadcast authority.
contract TestnetDeployScript is Script {
    error InvalidManifest();

    function run() external {
        string memory manifestPath = vm.envString("DEPLOYMENT_MANIFEST");
        string memory json = vm.readFile(manifestPath);
        uint256 chainId = vm.parseJsonUint(json, ".chainId");
        IPoolManager manager = IPoolManager(vm.parseJsonAddress(json, ".contracts.poolManager"));
        IERC20 weth = IERC20(vm.parseJsonAddress(json, ".contracts.weth"));
        address beneficiary = vm.parseJsonAddress(json, ".feeBeneficiary");
        bytes32 hookSalt = vm.parseJsonBytes32(json, ".root.hookSalt");
        uint160 sqrtPriceX96 = uint160(vm.parseJsonUint(json, ".launch.sqrtPriceX96"));
        address creator = vm.parseJsonAddress(json, ".token.creator");
        if (
            chainId != block.chainid || address(manager) == address(0) || address(weth) == address(0)
                || beneficiary == address(0) || creator == address(0) || sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE
                || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE || address(manager).code.length == 0
                || address(weth).code.length == 0
        ) revert InvalidManifest();

        uint64 nonce = vm.getNonce(creator);
        address expectedCoordinator = vm.computeCreateAddress(creator, nonce + 2);
        vm.startBroadcast();
        LooongRouter router = new LooongRouter(manager, expectedCoordinator, weth);
        LooongHookFactory factory = new LooongHookFactory(manager, expectedCoordinator, address(router), weth);
        LooongMarketCoordinatorV1 coordinator = new LooongMarketCoordinatorV1(manager, weth, hookSalt, router, factory);
        _openTokenMarket(coordinator, json, creator, beneficiary, sqrtPriceX96);
        vm.stopBroadcast();

        require(address(coordinator) == expectedCoordinator, "coordinator address mismatch");
        require(address(router.hook()) == address(coordinator.hook()), "router binding mismatch");
    }

    function _launchArgs(string memory json, address creator, address beneficiary, uint160 sqrtPriceX96)
        private
        view
        returns (LooongMarketCoordinatorV1.LaunchArgs memory)
    {
        return LooongMarketCoordinatorV1.LaunchArgs({
            name: vm.parseJsonString(json, ".token.name"),
            symbol: vm.parseJsonString(json, ".token.symbol"),
            tagline: vm.parseJsonString(json, ".token.tagline"),
            logoURI: vm.parseJsonString(json, ".token.logoURI"),
            expectedCreator: creator,
            feeBeneficiary: beneficiary,
            deploymentSalt: vm.parseJsonBytes32(json, ".token.deploymentSalt"),
            sqrtPriceX96: sqrtPriceX96
        });
    }

    function _openTokenMarket(
        LooongMarketCoordinatorV1 coordinator,
        string memory json,
        address creator,
        address beneficiary,
        uint160 sqrtPriceX96
    ) private {
        coordinator.openTokenMarket(
            _launchArgs(json, creator, beneficiary, sqrtPriceX96), vm.parseJsonAddress(json, ".token.expectedAddress")
        );
    }
}
