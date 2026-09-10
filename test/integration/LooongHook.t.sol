// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LooongHook} from "../../src/LooongHook.sol";
import {LooongHookFactory} from "../../src/LooongHookFactory.sol";
import {LooongRouter} from "../../src/LooongRouter.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {LooongLaunchV1} from "../utils/LooongExistingTokenFixture.sol";

contract LooongDonationRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    struct Request {
        address payer;
        PoolKey key;
        uint256 amount0;
        uint256 amount1;
    }

    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function donate(PoolKey calldata key, uint256 amount0, uint256 amount1) external {
        manager.unlock(abi.encode(Request(msg.sender, key, amount0, amount1)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        Request memory request = abi.decode(data, (Request));
        manager.donate(request.key, request.amount0, request.amount1, "");
        _settle(request.key.currency0, request.payer, request.amount0);
        _settle(request.key.currency1, request.payer, request.amount1);
        return "";
    }

    function _settle(Currency currency, address payer, uint256 amount) private {
        manager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), amount);
        require(manager.settle() == amount);
    }
}

contract LooongHookIntegrationTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    MockERC20 private looong;
    MockERC20 private weth;
    LooongLaunchV1 private launcher;
    LooongRouter private router;
    LooongHook private hook;
    PoolKey private key;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private beneficiary = makeAddr("beneficiary");

    function setUp() public {
        deployArtifactsAndLabel();
        looong = deployToken();
        weth = deployToken();
        launcher = new LooongLaunchV1(poolManager, IERC20(address(looong)), IERC20(address(weth)), beneficiary);
        router = launcher.router();

        (uint128 liquidity, uint256 amount0, uint256 amount1) = _initialLiquidity();
        uint256 looongMaximum = address(looong) < address(weth) ? amount0 + 1 : amount1 + 1;
        uint256 wethMaximum = address(looong) < address(weth) ? amount1 + 1 : amount0 + 1;
        looong.approve(address(launcher), looongMaximum);
        weth.approve(address(launcher), wethMaximum);
        (hook,,) = launcher.launch(
            _validSalt(launcher.factory()), Constants.SQRT_PRICE_1_1, liquidity, looongMaximum, wethMaximum
        );
        key = router.poolKey();

        looong.approve(address(router), type(uint256).max);
        weth.approve(address(router), type(uint256).max);
        weth.mint(alice, 100 ether);
        vm.prank(alice);
        weth.approve(address(router), type(uint256).max);
    }

    function test_atomicLaunchFreezesPoolAndPermissionBits() public view {
        assertTrue(launcher.launched());
        assertEq(address(key.hooks), address(hook));
        assertEq(key.fee, 3_000);
        assertEq(key.tickSpacing, 60);
        assertEq(uint160(address(hook)) & ((1 << 14) - 1), launcher.factory().REQUIRED_FLAGS());
        assertTrue(hook.poolIsLive(key.toId()));
        assertEq(address(router.looong()), address(looong));
        assertEq(address(router.weth()), address(weth));

        bytes32 positionKey = Position.calculatePositionKey(
            address(launcher), TickMath.minUsableTick(60), TickMath.maxUsableTick(60), bytes32(0)
        );
        assertEq(poolManager.getPositionLiquidity(key.toId(), positionKey), 1_000 ether);
    }

    function test_launchFitsTransactionAndDeploymentSizeBudgets() public {
        LooongLaunchV1 measured =
            new LooongLaunchV1(poolManager, IERC20(address(looong)), IERC20(address(weth)), beneficiary);
        (uint128 liquidity, uint256 amount0, uint256 amount1) = _initialLiquidity();
        uint256 looongMaximum = address(looong) < address(weth) ? amount0 + 1 : amount1 + 1;
        uint256 wethMaximum = address(looong) < address(weth) ? amount1 + 1 : amount0 + 1;
        looong.approve(address(measured), looongMaximum);
        weth.approve(address(measured), wethMaximum);
        bytes32 salt = _validSalt(measured.factory());

        uint256 gasBefore = gasleft();
        (LooongHook measuredHook,,) =
            measured.launch(salt, Constants.SQRT_PRICE_1_1, liquidity, looongMaximum, wethMaximum);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("atomic launch gas", gasUsed);
        assertLt(gasUsed, 12_000_000);
        assertLe(address(measured).code.length, 24_576);
        assertLe(address(measured.router()).code.length, 24_576);
        assertLe(address(measured.factory()).code.length, 24_576);
        assertLe(address(measuredHook).code.length, 24_576);
        assertLe(measured.factory().bytecodeStore().code.length, 24_576);
    }

    function test_invalidSaltRollsBackOneShotState() public {
        LooongLaunchV1 other =
            new LooongLaunchV1(poolManager, IERC20(address(looong)), IERC20(address(weth)), beneficiary);
        bytes32 invalidSalt = _invalidSalt(other.factory());
        looong.approve(address(other), 2 ether);
        weth.approve(address(other), 2 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                LooongHookFactory.InvalidHookAddress.selector, other.factory().computeAddress(invalidSalt)
            )
        );
        other.launch(invalidSalt, Constants.SQRT_PRICE_1_1, 1 ether, 2 ether, 2 ether);
        assertFalse(other.launched());
        assertFalse(other.router().bound());
        assertEq(address(other.hook()), address(0));
    }

    function test_verifiedBuyCreatesCustodiedPositionWithGrossBasis() public {
        uint256 wethBefore = weth.balanceOf(alice);
        vm.prank(alice);
        uint256 positionId = router.buy(1 ether, 1, _priceLimit(true), uint64(block.timestamp));

        (address owner, uint128 initialTokens, uint128 remainingTokens, uint256 basis) = _position(positionId);
        assertEq(owner, alice);
        assertGt(initialTokens, 0);
        assertEq(remainingTokens, initialTokens);
        assertEq(basis, 1 ether);
        assertEq(wethBefore - weth.balanceOf(alice), 1 ether);
        assertEq(looong.balanceOf(alice), 0);
        assertEq(looong.balanceOf(address(hook)), initialTokens);
        assertEq(hook.totalCustodiedTokens(), initialTokens);
        assertEq(hook.baseFeeLiability(), 0.001 ether);
        _assertConservation();
    }

    function test_partialSellAndWithdrawalConservePositionAndCustody() public {
        vm.startPrank(alice);
        uint256 positionId = router.buy(2 ether, 1, _priceLimit(true), uint64(block.timestamp));
        (, uint128 initialTokens,,) = _position(positionId);
        uint128 sold = initialTokens / 3;
        uint256 wethBefore = weth.balanceOf(alice);
        uint256 netOutput = router.sell(positionId, sold, 1, _priceLimit(false), uint64(block.timestamp));
        assertEq(weth.balanceOf(alice) - wethBefore, netOutput);
        assertGt(hook.sellerRebates(alice), 0);

        (, uint128 initialAfter, uint128 remainingAfter,) = _position(positionId);
        assertEq(initialAfter, initialTokens);
        uint128 withdrawn = remainingAfter / 2;
        uint256 aliceBaseBefore = looong.balanceOf(alice);
        hook.withdraw(positionId, withdrawn);
        assertEq(looong.balanceOf(alice) - aliceBaseBefore, withdrawn);

        _assertPositionConservation(positionId, sold, withdrawn);
        vm.stopPrank();
        _assertConservation();
    }

    function test_lossMakingExitReceivesTheFullComponent() public {
        vm.prank(alice);
        uint256 positionId = router.buy(2 ether, 1, _priceLimit(true), uint64(block.timestamp));
        (, uint128 tokens,,) = _position(positionId);
        uint256 claimsBefore = hook.accountedWethClaims();
        uint256 baseBefore = hook.baseFeeLiability();
        uint256 rebateBefore = hook.sellerRebates(alice);
        uint256 rewardsBefore = hook.totalScaledRewardLiability();

        vm.prank(alice);
        uint256 netOutput = router.sell(positionId, tokens / 4, 1, _priceLimit(false), uint64(block.timestamp));

        uint256 claimsDelta = hook.accountedWethClaims() - claimsBefore;
        uint256 baseDelta = hook.baseFeeLiability() - baseBefore;
        uint256 component = claimsDelta - baseDelta;
        (,,,,,,,,, uint256 soldBasis,,) = hook.positions(positionId);
        assertLe(netOutput + component, soldBasis);
        assertEq(hook.sellerRebates(alice) - rebateBefore, component);
        assertEq(hook.totalScaledRewardLiability(), rewardsBefore);
        _assertConservation();
    }

    function test_profitableExitWithNoOtherMatureHolderReceivesTheFullComponent() public {
        vm.prank(alice);
        uint256 positionId = router.buy(1 ether, 1, _priceLimit(true), uint64(block.timestamp));
        router.swapExactInput(true, 100 ether, 1, address(this), _priceLimit(true), uint64(block.timestamp));
        (, uint128 tokens,,) = _position(positionId);
        uint256 claimsBefore = hook.accountedWethClaims();
        uint256 baseBefore = hook.baseFeeLiability();
        uint256 rebateBefore = hook.sellerRebates(alice);
        uint256 rewardsBefore = hook.totalScaledRewardLiability();

        vm.prank(alice);
        uint256 netOutput = router.sell(positionId, tokens / 2, 1, _priceLimit(false), uint64(block.timestamp));

        uint256 claimsDelta = hook.accountedWethClaims() - claimsBefore;
        uint256 baseDelta = hook.baseFeeLiability() - baseBefore;
        uint256 component = claimsDelta - baseDelta;
        (,,,,,,,,, uint256 soldBasis,, uint256 profitRemainder) = hook.positions(positionId);
        assertGt(netOutput + component, soldBasis);
        assertEq(hook.sellerRebates(alice) - rebateBefore, component);
        assertEq(hook.totalScaledRewardLiability(), rewardsBefore);
        assertEq(profitRemainder, 0);
        _assertConservation();
    }

    function test_matureSharesEarnOrdinarySellRewardsAndClaimsCannotRedirect() public {
        vm.prank(alice);
        uint256 positionId = router.buy(2 ether, 1, _priceLimit(true), uint64(block.timestamp));
        vm.warp(block.timestamp + 30 days);
        hook.activatePosition(positionId);
        assertGt(hook.ownerShares(alice), 0);

        router.swapExactInput(false, 1 ether, 1, address(this), _priceLimit(false), uint64(block.timestamp));
        uint256 bobBefore = weth.balanceOf(bob);
        vm.prank(alice);
        uint256 reward = hook.claimRewards(key.toId(), bob);
        assertGt(reward, 0);
        assertEq(weth.balanceOf(bob) - bobBefore, reward);
        vm.expectRevert(LooongHook.ClaimUnavailable.selector);
        vm.prank(alice);
        hook.claimRewards(key.toId(), bob);
        _assertConservation();
    }

    function test_allFourOrdinaryQuadrantsAndCurrentWitness() public {
        uint256 exactInputBuyOut =
            router.swapExactInput(true, 1 ether, 1, address(this), _priceLimit(true), uint64(block.timestamp));
        assertGt(exactInputBuyOut, 0);
        uint256 exactInputSellOut = router.swapExactInput(
            false, uint128(exactInputBuyOut / 4), 1, address(this), _priceLimit(false), uint64(block.timestamp)
        );
        assertGt(exactInputSellOut, 0);

        uint256 exactOutputBuyIn = router.swapExactOutput(
            true, 0.1 ether, 2 ether, address(this), _priceLimit(true), uint64(block.timestamp), ""
        );
        assertGt(exactOutputBuyIn, 0);

        uint256 netWeth = 0.01 ether;
        uint256 grossWeth = hook.quoteExactOutputGross(netWeth, true);
        uint256 exactOutputSellIn = router.swapExactOutput(
            false,
            uint128(netWeth),
            2 ether,
            address(this),
            _priceLimit(false),
            uint64(block.timestamp),
            abi.encode(hook.WITNESS_DOMAIN(), grossWeth)
        );
        assertGt(exactOutputSellIn, 0);
        _assertConservation();
    }

    function test_baseAndRebateClaimsBurnExactPoolManagerClaims() public {
        vm.startPrank(alice);
        uint256 positionId = router.buy(2 ether, 1, _priceLimit(true), uint64(block.timestamp));
        (, uint128 tokens,,) = _position(positionId);
        router.sell(positionId, tokens / 2, 1, _priceLimit(false), uint64(block.timestamp));
        vm.stopPrank();

        uint256 rebate = hook.sellerRebates(alice);
        uint256 aliceBefore = weth.balanceOf(alice);
        hook.claimRebate(key.toId(), alice);
        assertEq(weth.balanceOf(alice) - aliceBefore, rebate);
        assertEq(hook.sellerRebates(alice), 0);

        uint256 baseFees = hook.baseFeeLiability();
        uint256 bobBefore = weth.balanceOf(bob);
        vm.prank(beneficiary);
        hook.claimBaseFees(key.toId(), bob);
        assertEq(weth.balanceOf(bob) - bobBefore, baseFees);
        assertEq(hook.baseFeeLiability(), 0);
        _assertConservation();
    }

    function test_profitableFreshExitRewardsOthersButExcludesAllSellerShares() public {
        weth.mint(bob, 10 ether);
        vm.prank(bob);
        weth.approve(address(router), type(uint256).max);

        vm.prank(alice);
        uint256 aliceMaturePosition = router.buy(2 ether, 1, _priceLimit(true), uint64(block.timestamp));
        vm.prank(bob);
        uint256 bobMaturePosition = router.buy(2 ether, 1, _priceLimit(true), uint64(block.timestamp));
        vm.warp(block.timestamp + 30 days);
        hook.activatePosition(aliceMaturePosition);
        hook.activatePosition(bobMaturePosition);

        vm.prank(alice);
        uint256 freshPosition = router.buy(1 ether, 1, _priceLimit(true), uint64(block.timestamp));
        router.swapExactInput(true, 100 ether, 1, address(this), _priceLimit(true), uint64(block.timestamp));
        (, uint128 freshTokens,,) = _position(freshPosition);
        uint256 scaledLiabilityBefore = hook.totalScaledRewardLiability();
        vm.prank(alice);
        router.sell(freshPosition, freshTokens, 1, _priceLimit(false), uint64(block.timestamp));

        assertEq(hook.sellerRebates(alice), 0);
        assertGt(hook.totalScaledRewardLiability(), scaledLiabilityBefore);
        vm.expectRevert(LooongHook.ClaimUnavailable.selector);
        vm.prank(alice);
        hook.claimRewards(key.toId(), alice);
        uint256 bobBefore = weth.balanceOf(bob);
        vm.prank(bob);
        uint256 bobReward = hook.claimRewards(key.toId(), bob);
        assertGt(bobReward, 0);
        assertEq(weth.balanceOf(bob) - bobBefore, bobReward);
        _assertConservation();
    }

    function test_matureExitReceivesFullComponentWhenOtherSharesExist() public {
        weth.mint(bob, 10 ether);
        vm.prank(bob);
        weth.approve(address(router), type(uint256).max);
        vm.prank(alice);
        uint256 alicePosition = router.buy(2 ether, 1, _priceLimit(true), uint64(block.timestamp));
        vm.prank(bob);
        uint256 bobPosition = router.buy(2 ether, 1, _priceLimit(true), uint64(block.timestamp));
        vm.warp(block.timestamp + 30 days);
        hook.activatePosition(alicePosition);
        hook.activatePosition(bobPosition);
        (, uint128 tokens,,) = _position(alicePosition);
        uint256 rewardsBefore = hook.totalScaledRewardLiability();
        vm.prank(alice);
        router.sell(alicePosition, tokens / 2, 1, _priceLimit(false), uint64(block.timestamp));
        assertGt(hook.sellerRebates(alice), 0);
        assertEq(hook.totalScaledRewardLiability(), rewardsBefore);
        _assertConservation();
    }

    function test_staleForgedAndExactInputWitnessesRevertWithoutAccountingChange() public {
        uint256 netWeth = 10_003;
        uint256 staleGross = hook.quoteExactOutputGross(netWeth, true);
        for (uint256 i; i < 50 && hook.quoteExactOutputGross(netWeth, true) == staleGross; ++i) {
            router.swapExactInput(
                true, uint128(1_001 + i), 1, address(this), _priceLimit(true), uint64(block.timestamp)
            );
        }
        assertNotEq(hook.quoteExactOutputGross(netWeth, true), staleGross);
        uint256 claimsBefore = hook.accountedWethClaims();
        bytes4 witnessDomain = hook.WITNESS_DOMAIN();
        bytes memory staleWitness = abi.encode(witnessDomain, staleGross);
        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        router.swapExactOutput(
            false, uint128(netWeth), 1 ether, address(this), _priceLimit(false), uint64(block.timestamp), staleWitness
        );
        assertEq(hook.accountedWethClaims(), claimsBefore);

        uint256 currentGross = hook.quoteExactOutputGross(netWeth, true);
        bytes memory forgedWitness = abi.encode(witnessDomain, currentGross + 1);
        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        router.swapExactOutput(
            false, uint128(netWeth), 1 ether, address(this), _priceLimit(false), uint64(block.timestamp), forgedWitness
        );

        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        poolSwapRouter.swap(
            key,
            SwapParams({
                zeroForOne: address(weth) < address(looong),
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: _priceLimit(true)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(witnessDomain, currentGross)
        );
        _assertConservation();
    }

    function test_verifiedPartialFillAndDirectCallbackCallsRollback() public {
        uint256 nextPositionBefore = hook.nextPositionId();
        uint256 aliceWethBefore = weth.balanceOf(alice);
        vm.expectPartialRevert(Pool.PriceLimitAlreadyExceeded.selector);
        vm.prank(alice);
        router.buy(1 ether, 1, Constants.SQRT_PRICE_1_1, uint64(block.timestamp));
        assertEq(hook.nextPositionId(), nextPositionBefore);
        assertEq(weth.balanceOf(alice), aliceWethBefore);

        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(
            address(router),
            key,
            SwapParams({
                zeroForOne: address(weth) < address(looong),
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: _priceLimit(true)
            }),
            ""
        );

        PoolKey memory wrongKey = key;
        wrongKey.fee = 500;
        vm.expectRevert(LooongHook.InvalidPool.selector);
        vm.prank(address(poolManager));
        hook.beforeSwap(
            address(router),
            wrongKey,
            SwapParams({
                zeroForOne: address(weth) < address(looong),
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: _priceLimit(true)
            }),
            ""
        );
    }

    function test_claimsDoNotResetLifetimeFeeRemainders() public {
        router.swapExactInput(true, 1_001, 1, address(this), _priceLimit(true), uint64(block.timestamp));
        uint256 baseRemainder = hook.baseFeeRemainder();
        uint256 componentRemainder = hook.componentFeeRemainder();
        vm.prank(beneficiary);
        hook.claimBaseFees(key.toId(), beneficiary);
        assertEq(hook.baseFeeRemainder(), baseRemainder);
        assertEq(hook.componentFeeRemainder(), componentRemainder);
        _assertConservation();
    }

    function test_donationsDoNotCreateFeesRewardsOrPositions() public {
        LooongDonationRouter donationRouter = new LooongDonationRouter(poolManager);
        looong.approve(address(donationRouter), type(uint256).max);
        weth.approve(address(donationRouter), type(uint256).max);
        uint256 claimsBefore = hook.accountedWethClaims();
        uint256 nextPositionBefore = hook.nextPositionId();
        uint256 custodyBefore = hook.totalCustodiedTokens();
        donationRouter.donate(key, 1 ether, 1 ether);
        assertEq(hook.accountedWethClaims(), claimsBefore);
        assertEq(hook.nextPositionId(), nextPositionBefore);
        assertEq(hook.totalCustodiedTokens(), custodyBefore);
        _assertConservation();
    }

    function test_consumedIntentCannotReplayAndMutationOrWrongRouterFails() public {
        uint64 deadline = uint64(block.timestamp);
        bool zeroForOne = address(weth) < address(looong);
        bytes32 replayedIntent = keccak256(
            abi.encode(
                hook.INTENT_DOMAIN(),
                block.chainid,
                address(hook),
                hook.canonicalPoolId(),
                alice,
                uint64(0),
                uint8(1),
                uint256(1),
                zeroForOne,
                uint128(1 ether),
                uint128(1),
                _priceLimit(true),
                deadline
            )
        );
        vm.prank(alice);
        router.buy(1 ether, 1, _priceLimit(true), deadline);
        (, address consumedOwner,,,,,,,,,) = hook.intents(replayedIntent);
        assertEq(consumedOwner, address(0));

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: _priceLimit(true)
        });
        bytes4 intentDomain = hook.INTENT_DOMAIN();
        bytes memory replayData = abi.encode(intentDomain, replayedIntent);
        vm.expectRevert(LooongHook.InvalidIntent.selector);
        vm.prank(address(poolManager));
        hook.beforeSwap(address(router), key, params, replayData);

        bytes32 staged;
        vm.prank(address(router));
        (staged,) = hook.stageBuy(alice, zeroForOne, 1 ether, 1, _priceLimit(true), deadline);
        bytes memory stagedData = abi.encode(intentDomain, staged);
        vm.expectRevert(LooongHook.OnlyRouter.selector);
        vm.prank(address(poolManager));
        hook.beforeSwap(address(this), key, params, stagedData);

        params.amountSpecified = -int256(1 ether + 1);
        vm.expectRevert(LooongHook.InvalidIntent.selector);
        vm.prank(address(poolManager));
        hook.beforeSwap(address(router), key, params, stagedData);
    }

    function test_ownerExpiryAndDomainFailuresRollback() public {
        vm.prank(alice);
        uint256 positionId = router.buy(1 ether, 1, _priceLimit(true), uint64(block.timestamp));
        (, uint128 tokens,,) = _position(positionId);
        uint256 custodyBefore = hook.totalCustodiedTokens();

        vm.expectRevert(LooongHook.NotPositionOwner.selector);
        vm.prank(bob);
        hook.withdraw(positionId, tokens / 4);
        vm.expectRevert(LooongHook.NotPositionOwner.selector);
        vm.prank(bob);
        router.sell(positionId, tokens / 4, 1, _priceLimit(false), uint64(block.timestamp));

        bool zeroForOne = address(weth) < address(looong);
        bytes32 staged;
        vm.prank(address(router));
        (staged,) = hook.stageBuy(alice, zeroForOne, 0.1 ether, 1, _priceLimit(true), uint64(block.timestamp));
        vm.warp(block.timestamp + 1);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -int256(0.1 ether), sqrtPriceLimitX96: _priceLimit(true)
        });
        bytes4 intentDomain = hook.INTENT_DOMAIN();
        vm.expectRevert(LooongHook.ExpiredIntent.selector);
        vm.prank(address(poolManager));
        hook.beforeSwap(address(router), key, params, abi.encode(intentDomain, staged));

        vm.expectRevert(LooongHook.InvalidHookData.selector);
        vm.prank(address(poolManager));
        hook.beforeSwap(address(router), key, params, abi.encode(bytes4(0xdeadbeef), bytes32(0)));
        assertEq(hook.totalCustodiedTokens(), custodyBefore);
        _assertConservation();
    }

    function test_allQuadrantsWorkWhenLooongSortsBeforeWeth() public {
        LooongLaunchV1 reverseLauncher =
            new LooongLaunchV1(poolManager, IERC20(address(weth)), IERC20(address(looong)), beneficiary);
        (uint128 liquidity, uint256 amount0, uint256 amount1) = _initialLiquidity();
        weth.approve(address(reverseLauncher), amount0 + 1);
        looong.approve(address(reverseLauncher), amount1 + 1);
        reverseLauncher.launch(
            _validSalt(reverseLauncher.factory()), Constants.SQRT_PRICE_1_1, liquidity, amount0 + 1, amount1 + 1
        );
        LooongRouter reverseRouter = reverseLauncher.router();
        weth.approve(address(reverseRouter), type(uint256).max);
        looong.approve(address(reverseRouter), type(uint256).max);
        bool reverseBuyZeroForOne = address(looong) < address(weth);
        uint160 buyLimit = reverseBuyZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint160 sellLimit = reverseBuyZeroForOne ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;

        uint256 buyOut =
            reverseRouter.swapExactInput(true, 1 ether, 1, address(this), buyLimit, uint64(block.timestamp));
        reverseRouter.swapExactInput(false, uint128(buyOut / 4), 1, address(this), sellLimit, uint64(block.timestamp));
        reverseRouter.swapExactOutput(true, 0.1 ether, 2 ether, address(this), buyLimit, uint64(block.timestamp), "");
        reverseRouter.swapExactOutput(false, 0.01 ether, 2 ether, address(this), sellLimit, uint64(block.timestamp), "");
        assertTrue(reverseLauncher.hook().claimsAreConserved());
    }

    function _position(uint256 positionId)
        private
        view
        returns (address owner, uint128 initialTokens, uint128 remainingTokens, uint256 initialBasis)
    {
        (owner,,, initialTokens, remainingTokens,,, initialBasis,,,,) = hook.positions(positionId);
    }

    function _assertConservation() private view {
        assertTrue(hook.custodyIsSolvent(key.toId()));
        assertTrue(hook.claimsAreConserved());
    }

    function _assertPositionConservation(uint256 positionId, uint128 expectedSold, uint128 expectedWithdrawn)
        private
        view
    {
        (
            ,,,
            uint128 initialTokens,
            uint128 remainingTokens,
            uint128 soldTokens,
            uint128 withdrawnTokens,
            uint256 initialBasis,
            uint256 remainingBasis,
            uint256 soldBasis,
            uint256 withdrawnBasis,
        ) = hook.positions(positionId);
        assertEq(soldTokens, expectedSold);
        assertEq(withdrawnTokens, expectedWithdrawn);
        assertEq(initialTokens, remainingTokens + soldTokens + withdrawnTokens);
        assertEq(initialBasis, remainingBasis + soldBasis + withdrawnBasis);
    }

    function _priceLimit(bool buyLooong) private view returns (uint160) {
        bool zeroForOne = buyLooong ? address(weth) < address(looong) : address(looong) < address(weth);
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _initialLiquidity() private pure returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        liquidity = 1_000 ether;
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(60)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(60)),
            liquidity
        );
    }

    function _validSalt(LooongHookFactory targetFactory) private view returns (bytes32 salt) {
        uint160 flags = targetFactory.REQUIRED_FLAGS();
        uint160 mask = targetFactory.ALL_FLAGS();
        bytes32 codeHash = targetFactory.creationCodeHash();
        for (uint256 i; i < 100_000; ++i) {
            salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(targetFactory), salt, codeHash)))));
            if (uint160(predicted) & mask == flags) return salt;
        }
        revert("salt not found");
    }

    function _invalidSalt(LooongHookFactory targetFactory) private view returns (bytes32 salt) {
        salt = bytes32(0);
        if (uint160(targetFactory.computeAddress(salt)) & targetFactory.ALL_FLAGS() == targetFactory.REQUIRED_FLAGS()) {
            salt = bytes32(uint256(1));
        }
    }
}
