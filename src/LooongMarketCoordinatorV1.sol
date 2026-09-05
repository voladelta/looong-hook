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
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {LooongHook} from "./LooongHook.sol";
import {LooongHookFactory} from "./LooongHookFactory.sol";
import {LooongRouter} from "./LooongRouter.sol";
import {LooongTokenV1} from "./LooongTokenV1.sol";

/// @notice Creates Hookr tokens and atomically opens their pools under one shared LOOONG root.
contract LooongMarketCoordinatorV1 is IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint256 public constant SUPPLY = 1_000_000_000e18;
    int24 public constant BAND_TICKS = 207_000;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_SYMBOL_BYTES = 16;
    uint256 public constant MAX_TAGLINE_BYTES = 160;
    uint256 public constant MAX_LOGO_URI_BYTES = 256;
    bytes32 public constant TOKEN_SALT_DOMAIN = keccak256("LOOONG_TOKEN_CREATE2_V1");
    bytes4 private constant LIQUIDITY_DOMAIN = bytes4(keccak256("LOOONG_FOUNDING_LIQUIDITY_V1"));
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct LaunchArgs {
        string name;
        string symbol;
        string tagline;
        string logoURI;
        address expectedCreator;
        address feeBeneficiary;
        bytes32 deploymentSalt;
        uint160 sqrtPriceX96;
    }

    struct LiquidityRequest {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 subjectMaximum;
    }

    error CallbackInProgress();
    error InvalidAddress();
    error InvalidLaunch();
    error InvalidLiquidityDelta();
    error InvalidTokenTransfer();
    error InvalidUnlock();
    error OnlyPoolManager();
    error TokenSaltAlreadyUsed(bytes32 salt, address token);
    error UnexpectedToken(address expected, address actual);

    event LooongMarketOpened(
        address indexed subject,
        PoolId indexed poolId,
        address indexed creator,
        address feeBeneficiary,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 subjectUsed
    );

    IPoolManager public immutable poolManager;
    IERC20 public immutable weth;
    LooongRouter public immutable router;
    LooongHookFactory public immutable factory;
    LooongHook public immutable hook;

    mapping(bytes32 create2Salt => address subject) public tokenByCreate2Salt;

    bool private _unlocking;
    bytes32 private _expectedUnlockHash;

    constructor(
        IPoolManager poolManager_,
        IERC20 weth_,
        bytes32 hookSalt,
        LooongRouter router_,
        LooongHookFactory factory_
    ) {
        if (
            address(poolManager_) == address(0) || address(weth_) == address(0) || address(router_) == address(0)
                || address(factory_) == address(0) || address(router_.poolManager()) != address(poolManager_)
                || address(router_.weth()) != address(weth_) || router_.binder() != address(this)
                || address(factory_.manager()) != address(poolManager_) || address(factory_.weth()) != address(weth_)
                || factory_.router() != address(router_) || factory_.registrar() != address(this)
        ) revert InvalidAddress();
        poolManager = poolManager_;
        weth = weth_;
        router = router_;
        factory = factory_;
        LooongHook deployedHook = factory_.deploy(hookSalt);
        hook = deployedHook;
        router_.bind(deployedHook);
    }

    function openTokenMarket(LaunchArgs calldata args, address expectedToken)
        external
        nonReentrant
        returns (address subject, PoolId poolId)
    {
        bytes32 create2Salt = _validateLaunch(args, expectedToken);
        subject = address(
            new LooongTokenV1{salt: create2Salt}(
                args.name, args.symbol, args.tagline, args.logoURI, args.expectedCreator, SUPPLY
            )
        );

        PoolKey memory key = router.poolKey(subject);
        hook.registerPool(key, args.feeBeneficiary);
        int24 openTick = TickMath.getTickAtSqrtPrice(args.sqrtPriceX96);
        if (openTick % TICK_SPACING != 0 || TickMath.getSqrtPriceAtTick(openTick) != args.sqrtPriceX96) {
            revert InvalidLaunch();
        }
        (int24 tickLower, int24 tickUpper) =
            subject < address(weth) ? (openTick, openTick + BAND_TICKS) : (openTick - BAND_TICKS, openTick);
        if (tickLower < TickMath.minUsableTick(TICK_SPACING)) revert InvalidLaunch();
        if (tickUpper > TickMath.maxUsableTick(TICK_SPACING)) revert InvalidLaunch();

        poolManager.initialize(key, args.sqrtPriceX96);
        uint128 liquidity = subject < address(weth)
            ? LiquidityAmounts.getLiquidityForAmount0(args.sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickUpper), SUPPLY)
            : LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(tickLower), args.sqrtPriceX96, SUPPLY);
        if (liquidity == 0) revert InvalidLaunch();
        uint256 subjectUsed = _addLiquidity(
            LiquidityRequest({
                key: key, tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity, subjectMaximum: SUPPLY
            })
        );
        if (subjectUsed == 0 || subjectUsed > SUPPLY) revert InvalidLiquidityDelta();
        uint256 residue = SUPPLY - subjectUsed;
        if (residue != 0) IERC20(subject).safeTransfer(DEAD, residue);
        if (IERC20(subject).balanceOf(address(this)) != 0) revert InvalidTokenTransfer();

        poolId = key.toId();
        tokenByCreate2Salt[create2Salt] = subject;
        _emitMarketOpened(args, subject, poolId, tickLower, tickUpper, subjectUsed);
    }

    function previewTokenAddress(LaunchArgs calldata args) external view returns (address predicted) {
        bytes32 salt = _tokenSalt(args.expectedCreator, args.deploymentSalt);
        predicted = _previewTokenAddress(args, salt);
    }

    function _validateLaunch(LaunchArgs calldata args, address expectedToken)
        private
        view
        returns (bytes32 create2Salt)
    {
        uint256 nameLength = bytes(args.name).length;
        uint256 symbolLength = bytes(args.symbol).length;
        if (
            args.expectedCreator != msg.sender || args.feeBeneficiary == address(0) || expectedToken == address(0)
                || nameLength == 0 || nameLength > MAX_NAME_BYTES || symbolLength == 0
                || symbolLength > MAX_SYMBOL_BYTES || bytes(args.tagline).length > MAX_TAGLINE_BYTES
                || bytes(args.logoURI).length > MAX_LOGO_URI_BYTES
        ) revert InvalidLaunch();

        create2Salt = _tokenSalt(args.expectedCreator, args.deploymentSalt);
        address prior = tokenByCreate2Salt[create2Salt];
        if (prior != address(0)) revert TokenSaltAlreadyUsed(create2Salt, prior);
        address predicted = _previewTokenAddress(args, create2Salt);
        if (predicted != expectedToken) revert UnexpectedToken(expectedToken, predicted);
    }

    function _previewTokenAddress(LaunchArgs calldata args, bytes32 salt) private view returns (address predicted) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(LooongTokenV1).creationCode,
                abi.encode(args.name, args.symbol, args.tagline, args.logoURI, args.expectedCreator, SUPPLY)
            )
        );
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, initCodeHash)))));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (!_unlocking || keccak256(data) != _expectedUnlockHash) revert InvalidUnlock();
        (bytes4 domain, LiquidityRequest memory request) = abi.decode(data, (bytes4, LiquidityRequest));
        if (domain != LIQUIDITY_DOMAIN) revert InvalidUnlock();

        (BalanceDelta delta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            request.key,
            ModifyLiquidityParams({
                tickLower: request.tickLower,
                tickUpper: request.tickUpper,
                liquidityDelta: int256(uint256(request.liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        if (feesAccrued.amount0() != 0 || feesAccrued.amount1() != 0) revert InvalidLiquidityDelta();
        int128 subjectDelta =
            Currency.unwrap(request.key.currency0) == address(weth) ? delta.amount1() : delta.amount0();
        int128 quoteDelta = Currency.unwrap(request.key.currency0) == address(weth) ? delta.amount0() : delta.amount1();
        if (subjectDelta >= 0 || quoteDelta != 0) revert InvalidLiquidityDelta();
        uint256 subjectUsed = uint256(-int256(subjectDelta));
        if (subjectUsed > request.subjectMaximum) revert InvalidLiquidityDelta();
        Currency subjectCurrency =
            Currency.unwrap(request.key.currency0) == address(weth) ? request.key.currency1 : request.key.currency0;
        poolManager.sync(subjectCurrency);
        IERC20(Currency.unwrap(subjectCurrency)).safeTransfer(address(poolManager), subjectUsed);
        if (poolManager.settle() != subjectUsed) revert InvalidTokenTransfer();
        return abi.encode(subjectUsed);
    }

    function _addLiquidity(LiquidityRequest memory request) private returns (uint256 subjectUsed) {
        if (_unlocking) revert CallbackInProgress();
        bytes memory data = abi.encode(LIQUIDITY_DOMAIN, request);
        _unlocking = true;
        _expectedUnlockHash = keccak256(data);
        subjectUsed = abi.decode(poolManager.unlock(data), (uint256));
        _unlocking = false;
        delete _expectedUnlockHash;
    }

    function _tokenSalt(address creator, bytes32 deploymentSalt) private pure returns (bytes32) {
        return keccak256(abi.encode(TOKEN_SALT_DOMAIN, creator, deploymentSalt));
    }

    function _emitMarketOpened(
        LaunchArgs calldata args,
        address subject,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint256 subjectUsed
    ) private {
        emit LooongMarketOpened(
            subject,
            poolId,
            args.expectedCreator,
            args.feeBeneficiary,
            args.sqrtPriceX96,
            tickLower,
            tickUpper,
            subjectUsed
        );
    }
}
