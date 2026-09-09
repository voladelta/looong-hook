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
import {ForcedWethClaims} from "../utils/ForcedWethClaims.sol";

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
        (address alpha, PoolId alphaPool) = _launchWithOrdering(alice, "Alpha", "ALPHA", 1, true);
        (address beta, PoolId betaPool) = _launchWithOrdering(bob, "Beta", "BETA", 1_000, false);

        assertTrue(alpha != beta);
        assertLt(uint160(alpha), uint160(address(weth)));
        assertGt(uint160(beta), uint160(address(weth)));
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

    function test_unsolicitedWethClaimSurplusDoesNotFreezeSharedRoot() public {
        (address alpha, PoolId alphaPool) = _launch(alice, "Alpha", "ALPHA", bytes32(uint256(10)));
        (address beta, PoolId betaPool) = _launch(bob, "Beta", "BETA", bytes32(uint256(11)));
        ForcedWethClaims donor = new ForcedWethClaims(poolManager, IERC20(address(weth)));

        weth.mint(address(donor), 1);
        weth.mint(alice, 1 ether);
        donor.donate(address(hook), 1, false);
        assertEq(hook.accountedWethClaims(), 0);
        assertEq(poolManager.balanceOf(address(hook), uint160(address(weth))), 1);
        assertTrue(hook.claimsAreConserved());

        vm.startPrank(alice);
        weth.approve(address(router), type(uint256).max);
        router.buy(alpha, 0.1 ether, 1, _priceLimit(alpha, true), uint64(block.timestamp));
        router.buy(beta, 0.1 ether, 1, _priceLimit(beta, true), uint64(block.timestamp));
        vm.stopPrank();

        vm.startPrank(beneficiary);
        hook.claimBaseFees(alphaPool, beneficiary);
        hook.claimBaseFees(betaPool, beneficiary);
        vm.stopPrank();

        assertEq(hook.accountedWethClaims(), 0);
        assertEq(poolManager.balanceOf(address(hook), uint160(address(weth))), 1);
        assertEq(hook.accountingLiabilityScaled(), 0);
        assertTrue(hook.claimsAreConserved());
    }

    function test_launchRejectsCreatorSubstitutionAndSaltReplay() public {
        LooongMarketCoordinatorV1.LaunchArgs memory args = _args(alice, "Alpha", "ALPHA", bytes32(uint256(3)));
        vm.expectRevert(LooongMarketCoordinatorV1.InvalidLaunch.selector);
        coordinator.openTokenMarket(args, address(0));

        address predicted = coordinator.previewTokenAddress(args);
        vm.prank(alice);
        vm.expectRevert(LooongMarketCoordinatorV1.InvalidLaunch.selector);
        coordinator.openTokenMarket(args, address(0));
        assertEq(predicted.code.length, 0);

        vm.prank(alice);
        coordinator.openTokenMarket(args, predicted);
        vm.prank(alice);
        vm.expectPartialRevert(LooongMarketCoordinatorV1.TokenSaltAlreadyUsed.selector);
        coordinator.openTokenMarket(args, predicted);
    }

    function test_forcedClaimsDoNotBlockEitherMarket() public {
        (address alpha, PoolId alphaPool) = _launchWithOrdering(alice, "Forced Alpha", "FALPHA", 2_000, true);
        (address beta, PoolId betaPool) = _launchWithOrdering(alice, "Forced Beta", "FBETA", 3_000, false);
        assertLt(uint160(alpha), uint160(address(weth)));
        assertGt(uint160(beta), uint160(address(weth)));
        ForcedWethClaims donor = new ForcedWethClaims(poolManager, IERC20(address(weth)));
        weth.mint(address(donor), 3);
        weth.mint(alice, 4 ether);
        vm.prank(alice);
        weth.approve(address(router), type(uint256).max);

        // Exercise both external ERC6909 entry points, followed by activity in both pools.
        donor.donate(address(hook), 1, true);
        _tradeAndRedeem(alpha, alphaPool, beta, betaPool);
        _tradeAndRedeem(beta, betaPool, alpha, alphaPool);
        assertEq(poolManager.balanceOf(address(hook), uint160(address(weth))) - hook.accountedWethClaims(), 1);

        donor.donate(address(hook), 2, false);
        _tradeAndRedeem(beta, betaPool, alpha, alphaPool);
        _tradeAndRedeem(alpha, alphaPool, beta, betaPool);
        assertEq(poolManager.balanceOf(address(hook), uint160(address(weth))) - hook.accountedWethClaims(), 3);
        assertTrue(hook.claimsAreConserved());
        assertEq(hook.accountedWethClaims(), 0);
        vm.prank(beneficiary);
        vm.expectRevert(LooongHook.ClaimUnavailable.selector);
        hook.claimBaseFees(alphaPool, beneficiary);
    }

    function _tradeAndRedeem(address subject, PoolId poolId, address other, PoolId otherPool) private {
        uint256 otherCustody = IERC20(other).balanceOf(address(hook));
        uint256 liabilityBefore = hook.totalBaseFeeLiability();
        vm.prank(alice);
        uint256 position = router.buy(subject, 1 ether, 1, _priceLimit(subject, true), uint64(block.timestamp));
        assertEq(PoolId.unwrap(hook.positionPools(position)), PoolId.unwrap(poolId));

        uint256 fees = hook.totalBaseFeeLiability() - liabilityBefore;
        uint256 recipientBefore = weth.balanceOf(beneficiary);
        vm.prank(beneficiary);
        assertEq(hook.claimBaseFees(poolId, beneficiary), fees);
        assertGt(fees, 0);
        assertEq(weth.balanceOf(beneficiary) - recipientBefore, fees);
        assertEq(hook.totalBaseFeeLiability(), liabilityBefore);
        assertEq(IERC20(other).balanceOf(address(hook)), otherCustody);
        assertTrue(hook.custodyIsSolvent(poolId));
        assertTrue(hook.custodyIsSolvent(otherPool));
    }

    function test_invalidPriceRollsBackTokenAndPoolRegistration() public {
        LooongMarketCoordinatorV1.LaunchArgs memory args = _args(alice, "Rollback", "BACK", bytes32(uint256(5)));
        address predicted = coordinator.previewTokenAddress(args);
        PoolId poolId = router.poolKey(predicted).toId();
        args.sqrtPriceX96 += 1;

        vm.prank(alice);
        vm.expectRevert(LooongMarketCoordinatorV1.InvalidLaunch.selector);
        coordinator.openTokenMarket(args, predicted);
        assertEq(predicted.code.length, 0);
        assertFalse(hook.poolIsLive(poolId));

        args.sqrtPriceX96 -= 1;
        vm.prank(alice);
        coordinator.openTokenMarket(args, predicted);
        assertTrue(hook.poolIsLive(poolId));
    }

    function test_launchFitsTransactionBudgetAndUnexpectedAddressRollsBack() public {
        LooongMarketCoordinatorV1.LaunchArgs memory args = _args(alice, "Alpha", "ALPHA", bytes32(uint256(4)));
        args.name = _filled(coordinator.MAX_NAME_BYTES(), bytes1("N"));
        args.symbol = _filled(coordinator.MAX_SYMBOL_BYTES(), bytes1("S"));
        args.tagline = _filled(coordinator.MAX_TAGLINE_BYTES(), bytes1("T"));
        args.logoURI = _filled(coordinator.MAX_LOGO_URI_BYTES(), bytes1("U"));
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

    function test_launchRejectsOversizedMetadataBeforeTokenCreation() public {
        LooongMarketCoordinatorV1.LaunchArgs memory args = _args(alice, "Alpha", "ALPHA", bytes32(uint256(5)));
        args.logoURI = _filled(coordinator.MAX_LOGO_URI_BYTES() + 1, bytes1("U"));
        address predicted = coordinator.previewTokenAddress(args);

        vm.prank(alice);
        vm.expectRevert(LooongMarketCoordinatorV1.InvalidLaunch.selector);
        coordinator.openTokenMarket(args, predicted);

        assertEq(predicted.code.length, 0);
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

    function _launchWithOrdering(
        address creator,
        string memory name,
        string memory symbol,
        uint256 saltStart,
        bool subjectBeforeWeth
    ) private returns (address subject, PoolId poolId) {
        for (uint256 salt = saltStart; salt < saltStart + 1_000; ++salt) {
            LooongMarketCoordinatorV1.LaunchArgs memory args = _args(creator, name, symbol, bytes32(salt));
            address predicted = coordinator.previewTokenAddress(args);
            if ((predicted < address(weth)) != subjectBeforeWeth) continue;
            vm.prank(creator);
            (subject, poolId) = coordinator.openTokenMarket(args, predicted);
            return (subject, poolId);
        }
        revert("ordered token address not found");
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

    function _filled(uint256 length, bytes1 value) private pure returns (string memory result) {
        bytes memory data = new bytes(length);
        for (uint256 i; i < length; ++i) {
            data[i] = value;
        }
        result = string(data);
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
