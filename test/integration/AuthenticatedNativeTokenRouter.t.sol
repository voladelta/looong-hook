// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {AuthenticatedNativeTokenRouter} from "../../src/router/AuthenticatedNativeTokenRouter.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {EasyPosm} from "../utils/libraries/EasyPosm.sol";

contract IdentityHook is BaseHook {
    bytes4 private constant ROUTE_DOMAIN = bytes4(keccak256("V4HOOK_NATIVE_TOKEN_SWAP_V1"));

    error InvalidRoute();

    address public immutable router;
    uint256 public swapCount;
    address public lastPayer;
    address public lastRecipient;
    bytes32 public lastProductDataHash;

    constructor(IPoolManager manager, address router_) BaseHook(manager) {
        router = router_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address sender, PoolKey calldata, SwapParams calldata, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (bytes4 domain, address payer, address recipient, bytes memory productData) =
            abi.decode(hookData, (bytes4, address, address, bytes));
        if (sender != router || domain != ROUTE_DOMAIN || payer == address(0) || recipient == address(0)) {
            revert InvalidRoute();
        }

        ++swapCount;
        lastPayer = payer;
        lastRecipient = recipient;
        lastProductDataHash = keccak256(productData);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

contract AuthenticatedNativeTokenRouterTest is BaseTest {
    using EasyPosm for IPositionManager;

    AuthenticatedNativeTokenRouter internal router;
    IdentityHook internal hook;
    MockERC20 internal token;
    PoolKey internal key;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address payable internal treasury = payable(makeAddr("treasury"));

    function setUp() public {
        deployArtifactsAndLabel();
        router = new AuthenticatedNativeTokenRouter(poolManager, address(this), treasury);
        token = deployToken();

        address flags = address(uint160(Hooks.BEFORE_SWAP_FLAG) ^ (0x5555 << 144));
        deployCodeTo(
            "AuthenticatedNativeTokenRouter.t.sol:IdentityHook", abi.encode(poolManager, address(router)), flags
        );
        hook = IdentityHook(flags);
        router.bind(Currency.wrap(address(token)), IHooks(address(hook)), 3000, 60);
        key = router.poolKey();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        token.approve(address(router), type(uint256).max);
        int24 lower = TickMath.minUsableTick(60);
        int24 upper = TickMath.maxUsableTick(60);
        uint128 liquidity = 100 ether;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), liquidity
        );
        vm.deal(address(this), amount0 + 1);
        positionManager.mint(key, lower, upper, liquidity, amount0 + 1, amount1 + 1, address(this), block.timestamp, "");
    }

    function test_realPoolManagerAllFourQuadrantsBindPayerAndRecipient() public {
        bytes memory productData = abi.encode("product-context");
        vm.deal(alice, 5 ether);
        uint256 bobBuyBalance;

        {
            vm.prank(alice);
            (uint256 exactInputBuyIn, uint256 exactInputBuyOut) =
                router.swapExactInput{value: 1 ether}(true, 1 ether, 1, bob, TickMath.MIN_SQRT_PRICE + 1, productData);
            assertEq(exactInputBuyIn, 1 ether);
            assertEq(token.balanceOf(bob), exactInputBuyOut);
            _assertLastRoute(alice, bob, productData, 1);
            bobBuyBalance = exactInputBuyOut;
        }

        {
            uint256 aliceNativeBefore = alice.balance;
            vm.prank(alice);
            uint256 exactOutputBuyIn = router.swapExactOutput{value: 1 ether}(
                true, 0.1 ether, 1 ether, alice, TickMath.MIN_SQRT_PRICE + 1, productData
            );
            assertEq(token.balanceOf(alice), 0.1 ether);
            assertEq(aliceNativeBefore - alice.balance, exactOutputBuyIn);
            _assertLastRoute(alice, alice, productData, 2);
        }

        vm.prank(bob);
        token.approve(address(router), bobBuyBalance / 10);
        {
            uint256 bobTokenBefore = token.balanceOf(bob);
            uint256 aliceNativeBeforeSell = alice.balance;
            vm.prank(bob);
            (uint256 exactInputSellIn, uint256 exactInputSellOut) = router.swapExactInput(
                false, uint128(bobBuyBalance / 10), 1, alice, TickMath.MAX_SQRT_PRICE - 1, productData
            );
            assertEq(exactInputSellIn, bobBuyBalance / 10);
            assertGt(exactInputSellOut, 0);
            assertEq(bobTokenBefore - token.balanceOf(bob), exactInputSellIn);
            assertEq(alice.balance - aliceNativeBeforeSell, exactInputSellOut);
            _assertLastRoute(bob, alice, productData, 3);
        }
        vm.prank(bob);
        token.approve(address(router), 0);

        vm.prank(alice);
        token.approve(address(router), 0.1 ether);
        {
            uint256 aliceTokenBeforeSell = token.balanceOf(alice);
            uint256 bobNativeBeforeSell = bob.balance;
            vm.prank(alice);
            uint256 exactOutputSellIn =
                router.swapExactOutput(false, 0.01 ether, 0.1 ether, bob, TickMath.MAX_SQRT_PRICE - 1, productData);
            assertGt(exactOutputSellIn, 0);
            assertEq(aliceTokenBeforeSell - token.balanceOf(alice), exactOutputSellIn);
            assertEq(bob.balance - bobNativeBeforeSell, 0.01 ether);
            _assertLastRoute(alice, bob, productData, 4);
        }
        vm.prank(alice);
        token.approve(address(router), 0);
    }

    function test_forcedNativeIsNotRefundedToNextCallerAndCanOnlyReachBoundRecipient() public {
        vm.deal(address(router), 7 ether);
        vm.deal(alice, 1 ether);
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        uint256 used =
            router.swapExactOutput{value: 1 ether}(true, 0.1 ether, 1 ether, alice, TickMath.MIN_SQRT_PRICE + 1, "");

        assertEq(aliceBefore - alice.balance, used);
        assertEq(address(router).balance, 7 ether);
        assertEq(treasury.balance, 0);
        assertEq(router.sweepForcedNative(), 7 ether);
        assertEq(treasury.balance, 7 ether);
        assertEq(address(router).balance, 0);
    }

    function test_spoofedFixtureRouterAndDirectUnlockCallbackAreRejected() public {
        bytes memory spoofed = abi.encode(router.ROUTE_DOMAIN(), alice, bob, bytes("spoofed"));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IdentityHook.InvalidRoute.selector),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        poolSwapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            spoofed
        );

        vm.expectRevert(AuthenticatedNativeTokenRouter.OnlyPoolManager.selector);
        router.unlockCallback("");
    }

    function test_partialFillSlippageRevertsSettlementAndIdentityState() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(AuthenticatedNativeTokenRouter.SlippageExceeded.selector);
        router.swapExactInput{value: 1 ether}(true, 1 ether, 1, alice, Constants.SQRT_PRICE_1_1 - 1, "");

        assertEq(token.balanceOf(alice), 0);
        assertEq(hook.swapCount(), 0);
        assertEq(address(router).balance, 0);
    }

    function test_zeroExactOutputIsRejectedBeforeUnlock() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(AuthenticatedNativeTokenRouter.InvalidAmount.selector);
        router.swapExactOutput{value: 1 ether}(true, 0, 1 ether, alice, TickMath.MIN_SQRT_PRICE + 1, "");
        assertEq(hook.swapCount(), 0);
    }

    function _assertLastRoute(address payer, address recipient, bytes memory productData, uint256 count) private view {
        assertEq(hook.swapCount(), count);
        assertEq(hook.lastPayer(), payer);
        assertEq(hook.lastRecipient(), recipient);
        assertEq(hook.lastProductDataHash(), keccak256(productData));
    }
}
