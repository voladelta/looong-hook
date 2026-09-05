// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {LooongHook} from "../../src/LooongHook.sol";
import {LooongHookFactory} from "../../src/LooongHookFactory.sol";
import {LooongRouter} from "../../src/LooongRouter.sol";

/// @notice Test-only existing-token bootstrap for exercising the shared root against arbitrary token orderings.
contract LooongLaunchV1 is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    bytes4 private constant LIQUIDITY_DOMAIN = bytes4(keccak256("LOOONG_INITIAL_LIQUIDITY_V1"));

    struct LiquidityRequest {
        PoolKey key;
        uint128 liquidity;
        uint256 amount0Maximum;
        uint256 amount1Maximum;
    }

    error AlreadyLaunched();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidLiquidityDelta();
    error InvalidTokenTransfer();
    error InvalidUnlock();
    error OnlyPoolManager();

    event Launched(address indexed hook, address indexed router, bytes32 indexed poolId);

    IPoolManager public immutable poolManager;
    IERC20 public immutable looong;
    IERC20 public immutable weth;
    address public immutable feeBeneficiary;
    LooongRouter public immutable router;
    LooongHookFactory public immutable factory;

    LooongHook public hook;
    bool public launched;
    bool private _unlocking;
    bytes32 private _expectedUnlockHash;

    constructor(IPoolManager manager_, IERC20 looong_, IERC20 weth_, address feeBeneficiary_) {
        if (
            address(manager_) == address(0) || address(looong_) == address(0) || address(weth_) == address(0)
                || feeBeneficiary_ == address(0) || address(looong_) == address(weth_)
        ) revert InvalidAddress();
        poolManager = manager_;
        looong = looong_;
        weth = weth_;
        feeBeneficiary = feeBeneficiary_;
        router = new LooongRouter(manager_, address(this), weth_);
        factory = new LooongHookFactory(manager_, address(this), address(router), weth_);
    }

    function launch(
        bytes32 salt,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 looongAmountMaximum,
        uint256 wethAmountMaximum
    ) external nonReentrant returns (LooongHook deployedHook, uint256 looongUsed, uint256 wethUsed) {
        if (launched) revert AlreadyLaunched();
        if (liquidity == 0 || looongAmountMaximum == 0 || wethAmountMaximum == 0) revert InvalidAmount();
        launched = true;

        deployedHook = factory.deploy(salt);
        hook = deployedHook;
        router.bind(deployedHook);
        router.setDefaultSubject(address(looong));
        PoolKey memory key = router.poolKey(address(looong));
        deployedHook.registerPool(key, feeBeneficiary);
        if (poolManager.initialize(key, sqrtPriceX96) != TickMath.getTickAtSqrtPrice(sqrtPriceX96)) {
            revert InvalidLiquidityDelta();
        }

        uint256 looongBalanceBefore = looong.balanceOf(address(this));
        uint256 wethBalanceBefore = weth.balanceOf(address(this));
        looong.safeTransferFrom(msg.sender, address(this), looongAmountMaximum);
        weth.safeTransferFrom(msg.sender, address(this), wethAmountMaximum);
        bool looongIsCurrency0 = Currency.unwrap(key.currency0) == address(looong);
        LiquidityRequest memory request = LiquidityRequest({
            key: key,
            liquidity: liquidity,
            amount0Maximum: looongIsCurrency0 ? looongAmountMaximum : wethAmountMaximum,
            amount1Maximum: looongIsCurrency0 ? wethAmountMaximum : looongAmountMaximum
        });
        (uint256 amount0Used, uint256 amount1Used) = _addLiquidity(request);
        looongUsed = looongIsCurrency0 ? amount0Used : amount1Used;
        wethUsed = looongIsCurrency0 ? amount1Used : amount0Used;
        _refund(looong, msg.sender, looongAmountMaximum - looongUsed);
        _refund(weth, msg.sender, wethAmountMaximum - wethUsed);
        if (
            looong.balanceOf(address(this)) != looongBalanceBefore || weth.balanceOf(address(this)) != wethBalanceBefore
        ) revert InvalidTokenTransfer();
        emit Launched(address(deployedHook), address(router), bytes32(PoolId.unwrap(key.toId())));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (!_unlocking || keccak256(data) != _expectedUnlockHash) revert InvalidUnlock();
        (bytes4 domain, LiquidityRequest memory request) = abi.decode(data, (bytes4, LiquidityRequest));
        if (domain != LIQUIDITY_DOMAIN) revert InvalidUnlock();
        (BalanceDelta delta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            request.key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: int256(uint256(request.liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        if (feesAccrued.amount0() != 0 || feesAccrued.amount1() != 0 || delta.amount0() >= 0 || delta.amount1() >= 0) {
            revert InvalidLiquidityDelta();
        }
        uint256 amount0Used = uint256(-int256(delta.amount0()));
        uint256 amount1Used = uint256(-int256(delta.amount1()));
        if (amount0Used > request.amount0Maximum || amount1Used > request.amount1Maximum) {
            revert InvalidLiquidityDelta();
        }
        _settle(request.key.currency0, amount0Used);
        _settle(request.key.currency1, amount1Used);
        return abi.encode(amount0Used, amount1Used);
    }

    function _addLiquidity(LiquidityRequest memory request) private returns (uint256 amount0Used, uint256 amount1Used) {
        bytes memory data = abi.encode(LIQUIDITY_DOMAIN, request);
        _unlocking = true;
        _expectedUnlockHash = keccak256(data);
        (amount0Used, amount1Used) = abi.decode(poolManager.unlock(data), (uint256, uint256));
        _unlocking = false;
        delete _expectedUnlockHash;
    }

    function _settle(Currency currency, uint256 amount) private {
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        if (poolManager.settle() != amount) revert InvalidTokenTransfer();
    }

    function _refund(IERC20 token, address recipient, uint256 amount) private {
        if (amount != 0) token.safeTransfer(recipient, amount);
    }
}
