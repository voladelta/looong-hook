// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {LooongHook} from "../src/LooongHook.sol";
import {LooongHookFactory} from "../src/LooongHookFactory.sol";
import {LooongMarketCoordinatorV1} from "../src/LooongMarketCoordinatorV1.sol";
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
        IERC20 subject;
        LooongDevnetToken weth;
        LooongMarketCoordinatorV1 coordinator;
        LooongHookFactory factory;
        LooongHook hook;
        LooongRouter router;
        bytes32 salt;
        PoolId poolId;
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
        deployment.weth = new LooongDevnetToken("Wrapped Ether", "WETH", deployer, 10_000_000 ether);
        for (uint256 i; i < TRADER_COUNT; ++i) {
            deployment.weth.devnetMint(traders[i], 2 ether);
        }

        uint64 nonce = vm.getNonce(deployer);
        address expectedCoordinator = vm.computeCreateAddress(deployer, nonce + 2);
        deployment.router = new LooongRouter(deployment.manager, expectedCoordinator, IERC20(address(deployment.weth)));
        deployment.factory = new LooongHookFactory(
            deployment.manager, expectedCoordinator, address(deployment.router), IERC20(address(deployment.weth))
        );
        deployment.salt = _findSalt(deployment.factory);
        deployment.coordinator = new LooongMarketCoordinatorV1(
            deployment.manager, IERC20(address(deployment.weth)), deployment.salt, deployment.router, deployment.factory
        );
        require(address(deployment.coordinator) == expectedCoordinator, "coordinator address mismatch");
        LooongMarketCoordinatorV1.LaunchArgs memory args = LooongMarketCoordinatorV1.LaunchArgs({
            name: "LOOONG Devnet",
            symbol: "LOOONG",
            tagline: "A token launched with LOOONG",
            logoURI: "ipfs://looong-devnet",
            expectedCreator: deployer,
            feeBeneficiary: deployer,
            deploymentSalt: bytes32(uint256(1)),
            sqrtPriceX96: Constants.SQRT_PRICE_1_1
        });
        (address subject, PoolId poolId) = deployment.coordinator.openTokenMarket(args, address(0));
        deployment.subject = IERC20(subject);
        deployment.poolId = poolId;
        deployment.hook = deployment.coordinator.hook();
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
            '  "poolId": "',
            vm.toString(bytes32(PoolId.unwrap(deployment.poolId))),
            '",\n',
            '  "salt": "',
            vm.toString(deployment.salt),
            '",\n',
            '  "contracts": {\n',
            '    "poolManager": "',
            vm.toString(address(deployment.manager)),
            '",\n',
            '    "subject": "',
            vm.toString(address(deployment.subject)),
            '",\n',
            '    "weth": "',
            vm.toString(address(deployment.weth)),
            '",\n',
            '    "coordinator": "',
            vm.toString(address(deployment.coordinator)),
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
