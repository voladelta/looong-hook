// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TestnetDeployScript} from "../../script/TestnetDeploy.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4PoolManagerDeployer} from "../utils/v4hook-testkit/artifacts/V4PoolManager.sol";
import {LooongDevnetToken} from "../../script/DevnetDeploy.s.sol";
import {LooongHookFactory} from "../../src/LooongHookFactory.sol";
import {LooongMarketCoordinatorV1} from "../../src/LooongMarketCoordinatorV1.sol";
import {LooongRouter} from "../../src/LooongRouter.sol";

contract TestnetPriceValidationTest is Test {
    TestnetDeployScript private deployment;

    function setUp() public {
        deployment = new TestnetDeployScript();
        vm.etch(address(0x1111), hex"00");
        vm.etch(address(0x2222), hex"00");
        vm.setEnv("DEPLOYMENT_MANIFEST", ".devnet/testnet-price.json");
        vm.createDir(".devnet", true);
    }

    function test_rejectsPriceBeforeUint160Narrowing() public {
        uint256[3] memory invalidPrices = [
            (uint256(1) << 160) + (uint256(1) << 96), uint256(TickMath.MIN_SQRT_PRICE), uint256(TickMath.MAX_SQRT_PRICE)
        ];
        for (uint256 i; i < invalidPrices.length; ++i) {
            _writePrice(invalidPrices[i]);
            vm.expectRevert(TestnetDeployScript.InvalidManifest.selector);
            deployment.run();
        }

        _writePrice(uint256(1) << 96);

        vm.expectPartialRevert(TestnetDeployScript.CreatorSenderMismatch.selector);
        deployment.run();
    }

    function _writePrice(uint256 price) private {
        vm.writeFile(
            ".devnet/testnet-price.json",
            string.concat(
                '{"chainId":',
                vm.toString(block.chainid),
                ',"contracts":{"poolManager":"0x0000000000000000000000000000000000001111",',
                '"weth":"0x0000000000000000000000000000000000002222"},',
                '"feeBeneficiary":"0x0000000000000000000000000000000000003333",',
                '"root":{"hookSalt":"0x0000000000000000000000000000000000000000000000000000000000000000",',
                '"expectedCoordinator":"0x0000000000000000000000000000000000004444"},',
                '"token":{"creator":"0x0000000000000000000000000000000000005555",',
                '"expectedAddress":"0x0000000000000000000000000000000000006666"},',
                '"launch":{"sqrtPriceX96":"',
                vm.toString(price),
                '"}}'
            )
        );
    }
}

/// @notice Local-only fixture for scripts/testnet-sender-check.sh. No wallet secrets are used.
contract TestnetDeployFixture is Script {
    struct ManifestConfig {
        address creator;
        address manager;
        address weth;
        address expectedCoordinator;
        address expectedToken;
        bytes32 hookSalt;
    }

    function run() external {
        require(block.chainid == 31337, "localhost only");
        address creator = address(0xBEEF);

        vm.startBroadcast();
        IPoolManager manager = IPoolManager(V4PoolManagerDeployer.deploy(address(0x4444)));
        IERC20 weth = IERC20(address(new LooongDevnetToken("Wrapped Ether", "WETH", creator, 1 ether)));
        vm.stopBroadcast();

        // These deployments only mine the salt in simulation, at the creator's actual nonce.
        address expectedCoordinator = vm.computeCreateAddress(creator, vm.getNonce(creator) + 2);
        vm.startPrank(creator);
        LooongRouter router = new LooongRouter(manager, expectedCoordinator, weth);
        LooongHookFactory factory = new LooongHookFactory(manager, expectedCoordinator, address(router), weth);
        vm.stopPrank();
        bytes32 salt;
        for (uint256 i; i < 200_000; ++i) {
            salt = bytes32(i);
            if (uint160(factory.computeAddress(salt)) & factory.ALL_FLAGS() == factory.REQUIRED_FLAGS()) break;
        }
        require(uint160(factory.computeAddress(salt)) & factory.ALL_FLAGS() == factory.REQUIRED_FLAGS(), "no salt");

        vm.startPrank(creator);
        LooongMarketCoordinatorV1 coordinator = new LooongMarketCoordinatorV1(manager, weth, salt, router, factory);
        vm.stopPrank();
        require(address(coordinator) == expectedCoordinator, "coordinator prediction");
        LooongMarketCoordinatorV1.LaunchArgs memory args = LooongMarketCoordinatorV1.LaunchArgs({
            name: "Sender proof",
            symbol: "PROOF",
            tagline: "Local proof",
            logoURI: "ipfs://proof",
            expectedCreator: creator,
            feeBeneficiary: creator,
            deploymentSalt: bytes32(uint256(1)),
            sqrtPriceX96: uint160(1 << 96)
        });
        address expectedToken = coordinator.previewTokenAddress(args);

        _writeManifest(
            ManifestConfig({
                creator: creator,
                manager: address(manager),
                weth: address(weth),
                expectedCoordinator: expectedCoordinator,
                expectedToken: expectedToken,
                hookSalt: salt
            })
        );
    }

    function _writeManifest(ManifestConfig memory config) private {
        vm.writeFile(
            ".devnet/testnet-sender.json",
            string.concat(
                '{"chainId":31337,"rpcEnv":"TESTNET_SENDER_RPC_URL","forkBlock":0,"feeBeneficiary":"',
                vm.toString(config.creator),
                '","contracts":{"poolManager":"',
                vm.toString(config.manager),
                '","weth":"',
                vm.toString(config.weth),
                '"},"root":{"expectedCoordinator":"',
                vm.toString(config.expectedCoordinator),
                '","hookSalt":"',
                vm.toString(config.hookSalt),
                '"},"token":{"name":"Sender proof","symbol":"PROOF","tagline":"Local proof",',
                '"logoURI":"ipfs://proof","creator":"',
                vm.toString(config.creator),
                '","deploymentSalt":"0x0000000000000000000000000000000000000000000000000000000000000001",',
                '"expectedAddress":"',
                vm.toString(config.expectedToken),
                '"},',
                '"launch":{"sqrtPriceX96":"79228162514264337593543950336"}}'
            )
        );
    }
}
