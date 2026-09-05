// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LooongHook} from "../../src/LooongHook.sol";
import {LooongHookFactory} from "../../src/LooongHookFactory.sol";
import {LooongMarketCoordinatorV1} from "../../src/LooongMarketCoordinatorV1.sol";
import {LooongRouter} from "../../src/LooongRouter.sol";
import {LooongTokenV1} from "../../src/LooongTokenV1.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract LooongMarketCoordinatorTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    uint256 private constant MAX_TRANSACTION_GAS = 12_000_000;

    MockERC20 private weth;
    LooongMarketCoordinatorV1 private coordinator;
    LooongHook private hook;
    LooongRouter private router;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private beneficiary = makeAddr("beneficiary");

    function setUp() public {
        deployArtifactsAndLabel();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        uint64 nonce = vm.getNonce(address(this));
        address expectedCoordinator = vm.computeCreateAddress(address(this), nonce + 2);
        router = new LooongRouter(poolManager, expectedCoordinator, IERC20(address(weth)));
        LooongHookFactory factory =
            new LooongHookFactory(poolManager, expectedCoordinator, address(router), IERC20(address(weth)));
        bytes32 hookSalt = _validSalt(factory);
        coordinator = new LooongMarketCoordinatorV1(poolManager, IERC20(address(weth)), hookSalt, router, factory);
        assertEq(address(coordinator), expectedCoordinator);
        hook = coordinator.hook();
    }

    function test_usersLaunchTwoTokensThroughOneSharedRoot() public {
        (address alpha, PoolId alphaPool) = _launch(alice, "Alpha", "ALPHA", bytes32(uint256(1)));
        (address beta, PoolId betaPool) = _launch(bob, "Beta", "BETA", bytes32(uint256(2)));

        assertTrue(alpha != beta);
        assertTrue(PoolId.unwrap(alphaPool) != PoolId.unwrap(betaPool));
        assertEq(address(router.hook()), address(hook));
        assertEq(address(router.poolKey(alpha).hooks), address(hook));
        assertEq(address(router.poolKey(beta).hooks), address(hook));
        assertTrue(hook.poolIsLive(alphaPool));
        assertTrue(hook.poolIsLive(betaPool));
        assertEq(LooongTokenV1(alpha).creator(), alice);
        assertEq(LooongTokenV1(beta).creator(), bob);
        assertEq(IERC20(alpha).balanceOf(address(coordinator)), 0);
        assertEq(IERC20(beta).balanceOf(address(coordinator)), 0);

        weth.mint(alice, 2 ether);
        vm.startPrank(alice);
        weth.approve(address(router), type(uint256).max);
        uint256 alphaPosition = router.buy(alpha, 1 ether, 1, _priceLimit(alpha, true), uint64(block.timestamp));
        uint256 betaPosition = router.buy(beta, 1 ether, 1, _priceLimit(beta, true), uint64(block.timestamp));
        vm.stopPrank();

        assertEq(PoolId.unwrap(hook.positionPools(alphaPosition)), PoolId.unwrap(alphaPool));
        assertEq(PoolId.unwrap(hook.positionPools(betaPosition)), PoolId.unwrap(betaPool));

        vm.prank(alice);
        vm.expectRevert(LooongHook.InvalidPool.selector);
        router.sell(beta, alphaPosition, 1, 1, _priceLimit(beta, false), uint64(block.timestamp));

        assertTrue(hook.custodyIsSolvent(alphaPool));
        assertTrue(hook.custodyIsSolvent(betaPool));
        assertTrue(hook.claimsAreConserved());
    }

    function test_launchRejectsCreatorSubstitutionAndSaltReplay() public {
        LooongMarketCoordinatorV1.LaunchArgs memory args = _args(alice, "Alpha", "ALPHA", bytes32(uint256(3)));
        vm.expectRevert(LooongMarketCoordinatorV1.InvalidLaunch.selector);
        coordinator.openTokenMarket(args, address(0));

        vm.prank(alice);
        coordinator.openTokenMarket(args, address(0));
        vm.prank(alice);
        vm.expectPartialRevert(LooongMarketCoordinatorV1.TokenSaltAlreadyUsed.selector);
        coordinator.openTokenMarket(args, address(0));
    }

    function test_launchFitsTransactionBudgetAndUnexpectedAddressRollsBack() public {
        LooongMarketCoordinatorV1.LaunchArgs memory args = _args(alice, "Alpha", "ALPHA", bytes32(uint256(4)));
        address predicted = coordinator.previewTokenAddress(args);

        vm.prank(alice);
        vm.expectPartialRevert(LooongMarketCoordinatorV1.UnexpectedToken.selector);
        coordinator.openTokenMarket(args, makeAddr("wrong token"));
        assertEq(predicted.code.length, 0);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        (address subject,) = coordinator.openTokenMarket(args, predicted);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(subject, predicted);
        assertLt(gasUsed, MAX_TRANSACTION_GAS);
    }

    function _launch(address creator, string memory name, string memory symbol, bytes32 salt)
        private
        returns (address subject, PoolId poolId)
    {
        LooongMarketCoordinatorV1.LaunchArgs memory args = _args(creator, name, symbol, salt);
        address predicted = coordinator.previewTokenAddress(args);
        vm.prank(creator);
        (subject, poolId) = coordinator.openTokenMarket(args, predicted);
        assertEq(subject, predicted);
    }

    function _args(address creator, string memory name, string memory symbol, bytes32 salt)
        private
        view
        returns (LooongMarketCoordinatorV1.LaunchArgs memory)
    {
        return LooongMarketCoordinatorV1.LaunchArgs({
            name: name,
            symbol: symbol,
            tagline: "A LOOONG launch",
            logoURI: "ipfs://looong",
            expectedCreator: creator,
            feeBeneficiary: beneficiary,
            deploymentSalt: salt,
            sqrtPriceX96: Constants.SQRT_PRICE_1_1
        });
    }

    function _priceLimit(address subject, bool buySubject) private view returns (uint160) {
        bool zeroForOne = buySubject ? address(weth) < subject : subject < address(weth);
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _validSalt(LooongHookFactory factory) private view returns (bytes32 salt) {
        uint160 required = factory.REQUIRED_FLAGS();
        uint160 mask = factory.ALL_FLAGS();
        for (uint256 i; i < 200_000; ++i) {
            salt = bytes32(i);
            if (uint160(factory.computeAddress(salt)) & mask == required) return salt;
        }
        revert("salt not found");
    }
}
