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
    struct DeploymentConfig {
        IPoolManager manager;
        IERC20 weth;
        address beneficiary;
        bytes32 hookSalt;
        uint160 sqrtPriceX96;
        address creator;
        address expectedToken;
        address expectedCoordinator;
    }

    error InvalidManifest();
    error CreatorSenderMismatch(address creator, address sender);

    function run() external {
        string memory manifestPath = vm.envString("DEPLOYMENT_MANIFEST");
        string memory json = vm.readFile(manifestPath);
        DeploymentConfig memory config = _readConfig(json);

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        if (sender != config.creator) revert CreatorSenderMismatch(config.creator, sender);

        uint64 nonce = vm.getNonce(sender);
        address predictedCoordinator = vm.computeCreateAddress(sender, nonce + 2);
        if (predictedCoordinator != config.expectedCoordinator) revert InvalidManifest();

        LooongRouter router = new LooongRouter(config.manager, config.expectedCoordinator, config.weth);
        LooongHookFactory factory =
            new LooongHookFactory(config.manager, config.expectedCoordinator, address(router), config.weth);
        LooongMarketCoordinatorV1 coordinator =
            new LooongMarketCoordinatorV1(config.manager, config.weth, config.hookSalt, router, factory);
        coordinator.openTokenMarket(_launchArgs(json, config), config.expectedToken);
        vm.stopBroadcast();

        require(address(coordinator) == config.expectedCoordinator, "coordinator address mismatch");
        require(address(router.hook()) == address(coordinator.hook()), "router binding mismatch");
    }

    function _readConfig(string memory json) private view returns (DeploymentConfig memory config) {
        uint256 chainId = vm.parseJsonUint(json, ".chainId");
        config.manager = IPoolManager(vm.parseJsonAddress(json, ".contracts.poolManager"));
        config.weth = IERC20(vm.parseJsonAddress(json, ".contracts.weth"));
        config.beneficiary = vm.parseJsonAddress(json, ".feeBeneficiary");
        config.hookSalt = vm.parseJsonBytes32(json, ".root.hookSalt");
        config.expectedCoordinator = vm.parseJsonAddress(json, ".root.expectedCoordinator");
        config.sqrtPriceX96 = uint160(vm.parseJsonUint(json, ".launch.sqrtPriceX96"));
        config.creator = vm.parseJsonAddress(json, ".token.creator");
        config.expectedToken = vm.parseJsonAddress(json, ".token.expectedAddress");
        if (
            chainId != block.chainid || address(config.manager) == address(0) || address(config.weth) == address(0)
                || config.beneficiary == address(0) || config.expectedCoordinator == address(0)
                || config.creator == address(0) || config.expectedToken == address(0)
                || config.sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE || config.sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE
                || address(config.manager).code.length == 0 || address(config.weth).code.length == 0
        ) revert InvalidManifest();
    }

    function _launchArgs(string memory json, DeploymentConfig memory config)
        private
        pure
        returns (LooongMarketCoordinatorV1.LaunchArgs memory)
    {
        return LooongMarketCoordinatorV1.LaunchArgs({
            name: vm.parseJsonString(json, ".token.name"),
            symbol: vm.parseJsonString(json, ".token.symbol"),
            tagline: vm.parseJsonString(json, ".token.tagline"),
            logoURI: vm.parseJsonString(json, ".token.logoURI"),
            expectedCreator: config.creator,
            feeBeneficiary: config.beneficiary,
            deploymentSalt: vm.parseJsonBytes32(json, ".token.deploymentSalt"),
            sqrtPriceX96: config.sqrtPriceX96
        });
    }
}
