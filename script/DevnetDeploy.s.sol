// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {LooongHook} from "../src/LooongHook.sol";
import {LooongHookFactory} from "../src/LooongHookFactory.sol";
import {LooongLaunchV1} from "../src/LooongLaunchV1.sol";
import {LooongRouter} from "../src/LooongRouter.sol";
import {V4PoolManagerDeployer} from "../test/utils/v4hook-testkit/artifacts/V4PoolManager.sol";

contract LooongDevnetToken is ERC20 {
    error OnlyMinter();

    address public immutable minter;

    constructor(string memory name_, string memory symbol_, address recipient, uint256 supply) ERC20(name_, symbol_) {
        minter = msg.sender;
        _mint(recipient, supply);
    }

    function devnetMint(address recipient, uint256 amount) external {
        if (msg.sender != minter) revert OnlyMinter();
        _mint(recipient, amount);
    }
}

/// @notice Deploys the full localhost product and writes its only deployment manifest.
contract DevnetDeployScript is Script {
    string private constant DEFAULT_MNEMONIC = "test test test test test test test test test test test junk";
    uint256 private constant TRADER_COUNT = 100;

    struct Deployment {
        IPoolManager manager;
        LooongDevnetToken looong;
        LooongDevnetToken weth;
        LooongLaunchV1 launcher;
        LooongHookFactory factory;
        LooongHook hook;
        LooongRouter router;
        bytes32 salt;
    }

    function run() external {
        string memory mnemonic = vm.envOr("DEVNET_MNEMONIC", DEFAULT_MNEMONIC);
        uint256 deployerKey = vm.deriveKey(mnemonic, uint32(0));
        address deployer = vm.addr(deployerKey);
        address[] memory traders = new address[](TRADER_COUNT);
        for (uint32 i; i < TRADER_COUNT; ++i) {
            traders[i] = vm.addr(vm.deriveKey(mnemonic, i));
        }

        Deployment memory deployment = _deploy(deployerKey, deployer, traders);
        _approveTraders(mnemonic, deployment.weth, deployment.router);
        _writeManifest(deployment);
    }

    function _deploy(uint256 deployerKey, address deployer, address[] memory traders)
        private
        returns (Deployment memory deployment)
    {
        vm.startBroadcast(deployerKey);
        deployment.manager = IPoolManager(V4PoolManagerDeployer.deploy(address(0x4444)));
        deployment.looong = new LooongDevnetToken("LOOONG", "LOOONG", deployer, 10_000_000 ether);
        deployment.weth = new LooongDevnetToken("Wrapped Ether", "WETH", deployer, 10_000_000 ether);
        for (uint256 i; i < TRADER_COUNT; ++i) {
            deployment.weth.devnetMint(traders[i], 2 ether);
        }

        deployment.launcher = new LooongLaunchV1(deployment.manager, deployment.looong, deployment.weth, deployer);
        deployment.factory = deployment.launcher.factory();
        deployment.salt = _findSalt(deployment.factory);
        uint128 liquidity = 10_000 ether;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(60)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(60)),
            liquidity
        );
        uint256 looongMaximum = address(deployment.looong) < address(deployment.weth) ? amount0 + 1 : amount1 + 1;
        uint256 wethMaximum = address(deployment.looong) < address(deployment.weth) ? amount1 + 1 : amount0 + 1;
        deployment.looong.approve(address(deployment.launcher), looongMaximum);
        deployment.weth.approve(address(deployment.launcher), wethMaximum);
        (deployment.hook,,) = deployment.launcher
        .launch(deployment.salt, Constants.SQRT_PRICE_1_1, liquidity, looongMaximum, wethMaximum);
        deployment.router = deployment.launcher.router();
        vm.stopBroadcast();
    }

    function _approveTraders(string memory mnemonic, LooongDevnetToken weth, LooongRouter router) private {
        for (uint32 i; i < TRADER_COUNT; ++i) {
            vm.startBroadcast(vm.deriveKey(mnemonic, i));
            weth.approve(address(router), type(uint256).max);
            vm.stopBroadcast();
        }
    }

    function _findSalt(LooongHookFactory factory) private view returns (bytes32 salt) {
        uint160 requiredFlags = factory.REQUIRED_FLAGS();
        uint160 mask = factory.ALL_FLAGS();
        for (uint256 i; i < 200_000; ++i) {
            salt = bytes32(i);
            if (uint160(factory.computeAddress(salt)) & mask == requiredFlags) return salt;
        }
        revert("permission salt not found");
    }

    function _writeManifest(Deployment memory deployment) private {
        string memory json = string.concat(
            "{\n",
            '  "chainId": ',
            vm.toString(block.chainid),
            ",\n",
            '  "network": "looong-devnet",\n',
            '  "rpcUrl": "',
            vm.envString("DEVNET_RPC_URL"),
            '",\n',
            '  "pool": {"fee": 3000, "tickSpacing": 60},\n',
            '  "salt": "',
            vm.toString(deployment.salt),
            '",\n',
            '  "contracts": {\n',
            '    "poolManager": "',
            vm.toString(address(deployment.manager)),
            '",\n',
            '    "looong": "',
            vm.toString(address(deployment.looong)),
            '",\n',
            '    "weth": "',
            vm.toString(address(deployment.weth)),
            '",\n',
            '    "launcher": "',
            vm.toString(address(deployment.launcher)),
            '",\n',
            '    "factory": "',
            vm.toString(address(deployment.factory)),
            '",\n',
            '    "hook": "',
            vm.toString(address(deployment.hook)),
            '",\n',
            '    "router": "',
            vm.toString(address(deployment.router)),
            '"\n',
            "  }\n",
            "}\n"
        );
        vm.writeFile(".devnet/deployment.json", json);
    }
}
