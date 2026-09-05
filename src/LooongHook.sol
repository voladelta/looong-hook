// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {ILooongHook} from "./interfaces/ILooongHook.sol";
import {LooongAccounting} from "./libraries/LooongAccounting.sol";

/// @notice Shared accounting and custody root for Hookr tokens paired with one WETH currency.
contract LooongHook is BaseHook, IUnlockCallback, ReentrancyGuard, ILooongHook {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint24 public constant LP_FEE = 3_000;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant MATURITY = 30 days;
    uint256 public constant REWARD_PRECISION = 1e27;
    uint256 public constant MIN_GROSS_WETH = 1_000;

    bytes4 public constant INTENT_DOMAIN = bytes4(keccak256("LOOONG_VERIFIED_INTENT_V1"));
    bytes4 public constant WITNESS_DOMAIN = bytes4(keccak256("LOOONG_EXACT_OUTPUT_WITNESS_V1"));
    bytes4 private constant REDEEM_DOMAIN = bytes4(keccak256("LOOONG_CLAIM_REDEEM_V1"));

    uint8 private constant BUY_INTENT = 1;
    uint8 private constant SELL_INTENT = 2;

    struct Position {
        address owner;
        uint64 openedAt;
        bool rewardActive;
        uint128 initialTokens;
        uint128 remainingTokens;
        uint128 soldTokens;
        uint128 withdrawnTokens;
        uint256 initialBasis;
        uint256 remainingBasis;
        uint256 soldBasis;
        uint256 withdrawnBasis;
        uint256 profitRemainder;
    }

    struct Intent {
        PoolId poolId;
        address owner;
        uint64 deadline;
        uint64 nonce;
        uint8 kind;
        bool claimed;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
        uint256 positionId;
    }

    struct PendingSwap {
        PoolId poolId;
        address subject;
        bytes32 intentId;
        address owner;
        uint256 positionId;
        uint256 grossWeth;
        uint256 baseFee;
        uint256 componentFee;
        uint256 witnessGross;
        int128 expectedWethDelta;
        uint128 exactInput;
        uint128 minimumOutput;
        uint8 kind;
        bool sell;
        bool exactInputMode;
        bool wethSpecified;
    }

    struct PoolState {
        address subject;
        address feeBeneficiary;
        bool registered;
        bool initialized;
        uint256 totalCustodiedTokens;
        uint256 baseFeeRemainder;
        uint256 componentFeeRemainder;
        uint256 baseFeeLiability;
        uint256 totalRebateLiability;
        uint256 totalScaledRewardLiability;
        uint256 cumulativeRewardPerShare;
        uint256 rewardDustScaled;
        uint256 totalEligibleShares;
    }

    error AccountingInvariant();
    error AlreadyInitialized();
    error AlreadyRegistered();
    error AmountTooLarge();
    error CallbackInProgress();
    error ClaimUnavailable();
    error ExpiredIntent();
    error InsufficientPosition();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidHookData();
    error InvalidIntent();
    error InvalidPool();
    error InvalidRecipient();
    error InvalidTokenTransfer();
    error InvalidWitness();
    error NotInitialized();
    error NotMature();
    error NotPositionOwner();
    error NotRegistered();
    error OnlyBeneficiary();
    error OnlyPoolManager();
    error OnlyRegistrar();
    error OnlyRouter();
    error PartialFill();
    error PositionNotFound();
    error ReplayedIntent();
    error UnsupportedExactOutput();

    event PoolRegistered(PoolId indexed poolId, address indexed subject, address indexed feeBeneficiary);
    event PositionOpened(
        PoolId indexed poolId, uint256 indexed positionId, address indexed owner, uint256 tokens, uint256 wethBasis
    );
    event PositionSold(
        PoolId indexed poolId,
        uint256 indexed positionId,
        address indexed owner,
        uint256 tokens,
        uint256 wethBasis,
        uint256 grossWeth,
        uint256 rebate,
        uint256 reward
    );
    event PositionWithdrawn(
        PoolId indexed poolId, uint256 indexed positionId, address indexed owner, uint256 tokens, uint256 wethBasis
    );
    event PositionActivated(PoolId indexed poolId, uint256 indexed positionId, address indexed owner, uint256 shares);
    event BaseFeesClaimed(PoolId indexed poolId, address indexed recipient, uint256 amount);
    event RebateClaimed(PoolId indexed poolId, address indexed seller, uint256 amount);
    event RewardsClaimed(PoolId indexed poolId, address indexed owner, address indexed recipient, uint256 amount);

    IPoolManager public immutable manager;
    address public immutable registrar;
    address public immutable trustedRouter;
    IERC20 public immutable weth;
    uint256 public nextPositionId = 1;
    uint256 public totalBaseFeeLiability;
    uint256 public totalRebateLiability;
    uint256 public totalScaledRewardLiability;
    PoolId private _legacyPoolId;

    mapping(PoolId poolId => PoolState state) private _pools;
    mapping(uint256 positionId => Position) public positions;
    mapping(uint256 positionId => PoolId poolId) public positionPools;
    mapping(PoolId poolId => mapping(address owner => uint64 nonce)) public ownerNonces;
    mapping(bytes32 intentId => Intent) public intents;
    mapping(PoolId poolId => mapping(address seller => uint256 amount)) private _sellerRebates;
    mapping(PoolId poolId => mapping(address owner => uint256 shares)) private _ownerShares;
    mapping(PoolId poolId => mapping(address owner => uint256 index)) private _ownerRewardIndex;
    mapping(PoolId poolId => mapping(address owner => uint256 scaledCredit)) private _ownerScaledRewardCredit;
    mapping(address subject => uint256 amount) public totalCustodiedByToken;

    PendingSwap private _pendingSwap;
    bool private _swapOpen;
    bool private _redeeming;
    bytes32 private _expectedRedeemHash;

    constructor(IPoolManager manager_, address registrar_, address trustedRouter_, IERC20 weth_) BaseHook(manager_) {
        if (
            address(manager_) == address(0) || registrar_ == address(0) || trustedRouter_ == address(0)
                || address(weth_) == address(0)
        ) revert InvalidAddress();
        manager = manager_;
        registrar = registrar_;
        trustedRouter = trustedRouter_;
        weth = weth_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function registerPool(PoolKey calldata key, address feeBeneficiary) external nonReentrant {
        _requireIdle();
        if (msg.sender != registrar) revert OnlyRegistrar();
        if (feeBeneficiary == address(0)) revert InvalidAddress();
        address subject = _validatePoolShape(key);
        PoolId poolId = key.toId();
        PoolState storage pool = _pools[poolId];
        if (pool.registered) revert AlreadyRegistered();
        pool.subject = subject;
        pool.feeBeneficiary = feeBeneficiary;
        pool.registered = true;
        if (PoolId.unwrap(_legacyPoolId) == bytes32(0)) _legacyPoolId = poolId;
        emit PoolRegistered(poolId, subject, feeBeneficiary);
    }

    function stageBuy(
        PoolId poolId,
        address owner,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        uint160 sqrtPriceLimitX96,
        uint64 deadline
    ) public nonReentrant returns (bytes32 intentId, uint256 positionId) {
        _requireStage(poolId, owner, amountIn, deadline);
        positionId = nextPositionId;
        uint64 nonce = ownerNonces[poolId][owner]++;
        intentId = keccak256(
            abi.encode(
                INTENT_DOMAIN,
                block.chainid,
                address(this),
                poolId,
                owner,
                nonce,
                BUY_INTENT,
                positionId,
                zeroForOne,
                amountIn,
                amountOutMinimum,
                sqrtPriceLimitX96,
                deadline
            )
        );
        intents[intentId] = Intent({
            poolId: poolId,
            owner: owner,
            deadline: deadline,
            nonce: nonce,
            kind: BUY_INTENT,
            claimed: false,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: sqrtPriceLimitX96,
            positionId: positionId
        });
    }

    function stageSell(
        PoolId poolId,
        address owner,
        uint256 positionId,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        uint160 sqrtPriceLimitX96,
        uint64 deadline
    ) public nonReentrant returns (bytes32 intentId) {
        _requireStage(poolId, owner, amountIn, deadline);
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert PositionNotFound();
        if (PoolId.unwrap(positionPools[positionId]) != PoolId.unwrap(poolId)) revert InvalidPool();
        if (position.owner != owner) revert NotPositionOwner();
        if (amountIn > position.remainingTokens) revert InsufficientPosition();
        uint64 nonce = ownerNonces[poolId][owner]++;
        intentId = keccak256(
            abi.encode(
                INTENT_DOMAIN,
                block.chainid,
                address(this),
                poolId,
                owner,
                nonce,
                SELL_INTENT,
                positionId,
                zeroForOne,
                amountIn,
                amountOutMinimum,
                sqrtPriceLimitX96,
                deadline
            )
        );
        intents[intentId] = Intent({
            poolId: poolId,
            owner: owner,
            deadline: deadline,
            nonce: nonce,
            kind: SELL_INTENT,
            claimed: false,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: sqrtPriceLimitX96,
            positionId: positionId
        });
    }

    function stageBuy(
        address owner,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        uint160 sqrtPriceLimitX96,
        uint64 deadline
    ) external returns (bytes32 intentId, uint256 positionId) {
        return stageBuy(_legacyPoolId, owner, zeroForOne, amountIn, amountOutMinimum, sqrtPriceLimitX96, deadline);
    }

    function stageSell(
        address owner,
        uint256 positionId,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        uint160 sqrtPriceLimitX96,
        uint64 deadline
    ) external returns (bytes32 intentId) {
        return stageSell(
            _legacyPoolId, owner, positionId, zeroForOne, amountIn, amountOutMinimum, sqrtPriceLimitX96, deadline
        );
    }

    function activatePosition(uint256 positionId) external nonReentrant {
        _requireIdle();
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert PositionNotFound();
        if (block.timestamp < uint256(position.openedAt) + MATURITY) revert NotMature();
        if (position.rewardActive) return;

        PoolId poolId = positionPools[positionId];
        PoolState storage pool = _pools[poolId];
        _checkpoint(poolId, position.owner, pool);
        position.rewardActive = true;
        _ownerShares[poolId][position.owner] += position.remainingTokens;
        pool.totalEligibleShares += position.remainingTokens;
        _indexRewardDust(poolId, address(0), pool);
        emit PositionActivated(poolId, positionId, position.owner, position.remainingTokens);
    }

    function withdraw(uint256 positionId, uint128 amount) external nonReentrant {
        _requireIdle();
        if (amount == 0) revert InvalidAmount();
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert PositionNotFound();
        if (position.owner != msg.sender) revert NotPositionOwner();
        if (amount > position.remainingTokens) revert InsufficientPosition();

        PoolId poolId = positionPools[positionId];
        PoolState storage pool = _pools[poolId];
        address owner = position.owner;
        uint256 basis = _reducePosition(position, amount, false, poolId, pool);
        pool.totalCustodiedTokens -= amount;
        totalCustodiedByToken[pool.subject] -= amount;
        if (position.remainingTokens == 0) {
            delete positions[positionId];
            positionPools[positionId] = PoolId.wrap(bytes32(0));
        }
        _transferBaseExact(pool.subject, owner, amount);
        emit PositionWithdrawn(poolId, positionId, owner, amount, basis);
        _assertCustody(pool.subject);
    }

    function claimBaseFees(PoolId poolId, address recipient) public nonReentrant returns (uint256 amount) {
        _requireIdle();
        PoolState storage pool = _registeredPool(poolId);
        if (msg.sender != pool.feeBeneficiary) revert OnlyBeneficiary();
        if (recipient == address(0)) revert InvalidRecipient();
        amount = pool.baseFeeLiability;
        if (amount == 0) revert ClaimUnavailable();
        pool.baseFeeLiability = 0;
        totalBaseFeeLiability -= amount;
        _redeemClaims(recipient, amount);
        emit BaseFeesClaimed(poolId, recipient, amount);
    }

    function claimRebate(PoolId poolId, address seller) public nonReentrant returns (uint256 amount) {
        _requireIdle();
        PoolState storage pool = _registeredPool(poolId);
        if (seller == address(0)) revert InvalidRecipient();
        amount = _sellerRebates[poolId][seller];
        if (amount == 0) revert ClaimUnavailable();
        _sellerRebates[poolId][seller] = 0;
        pool.totalRebateLiability -= amount;
        totalRebateLiability -= amount;
        _redeemClaims(seller, amount);
        emit RebateClaimed(poolId, seller, amount);
    }

    function claimRewards(PoolId poolId, address recipient) public nonReentrant returns (uint256 amount) {
        _requireIdle();
        PoolState storage pool = _registeredPool(poolId);
        if (recipient == address(0)) revert InvalidRecipient();
        _checkpoint(poolId, msg.sender, pool);
        uint256 scaledCredit = _ownerScaledRewardCredit[poolId][msg.sender];
        amount = scaledCredit / REWARD_PRECISION;
        if (amount == 0) revert ClaimUnavailable();
        uint256 claimedScaled = amount * REWARD_PRECISION;
        _ownerScaledRewardCredit[poolId][msg.sender] = scaledCredit - claimedScaled;
        pool.totalScaledRewardLiability -= claimedScaled;
        totalScaledRewardLiability -= claimedScaled;
        _redeemClaims(recipient, amount);
        emit RewardsClaimed(poolId, msg.sender, recipient, amount);
    }

    function quoteExactOutputGross(PoolId poolId, uint256 netWeth, bool sell) external view returns (uint256) {
        PoolState storage pool = _pools[poolId];
        return LooongAccounting.solveGross(netWeth, sell, pool.baseFeeRemainder, pool.componentFeeRemainder);
    }

    function accountedWethClaims() public view returns (uint256) {
        return manager.balanceOf(address(this), uint160(address(weth)));
    }

    function accountingLiabilityScaled() public view returns (uint256) {
        return (totalBaseFeeLiability + totalRebateLiability) * REWARD_PRECISION + totalScaledRewardLiability;
    }

    function custodyIsSolvent(PoolId poolId) external view returns (bool) {
        PoolState storage pool = _pools[poolId];
        return pool.subject != address(0)
            && IERC20(pool.subject).balanceOf(address(this)) >= totalCustodiedByToken[pool.subject];
    }

    function poolIsLive(PoolId poolId) external view returns (bool) {
        PoolState storage pool = _pools[poolId];
        return pool.registered && pool.initialized;
    }

    function sellerRebates(PoolId poolId, address seller) external view returns (uint256) {
        return _sellerRebates[poolId][seller];
    }

    function ownerShares(PoolId poolId, address owner) external view returns (uint256) {
        return _ownerShares[poolId][owner];
    }

    function ownerScaledRewardCredit(PoolId poolId, address owner) external view returns (uint256) {
        return _ownerScaledRewardCredit[poolId][owner];
    }

    function claimsAreConserved() public view returns (bool) {
        return accountedWethClaims() * REWARD_PRECISION >= accountingLiabilityScaled();
    }

    // Compatibility reads for the repository's original single-market consumers. New integrations
    // must use PoolId-scoped getters.
    function canonicalPoolId() external view returns (PoolId) {
        return _legacyPoolId;
    }

    function totalCustodiedTokens() external view returns (uint256) {
        return _pools[_legacyPoolId].totalCustodiedTokens;
    }

    function totalCustodiedTokens(PoolId poolId) external view returns (uint256) {
        return _pools[poolId].totalCustodiedTokens;
    }

    function baseFeeRemainder() external view returns (uint256) {
        return _pools[_legacyPoolId].baseFeeRemainder;
    }

    function componentFeeRemainder() external view returns (uint256) {
        return _pools[_legacyPoolId].componentFeeRemainder;
    }

    function baseFeeLiability() external view returns (uint256) {
        return _pools[_legacyPoolId].baseFeeLiability;
    }

    function sellerRebates(address seller) external view returns (uint256) {
        return _sellerRebates[_legacyPoolId][seller];
    }

    function ownerShares(address owner) external view returns (uint256) {
        return _ownerShares[_legacyPoolId][owner];
    }

    function quoteExactOutputGross(uint256 netWeth, bool sell) external view returns (uint256) {
        PoolState storage pool = _pools[_legacyPoolId];
        return LooongAccounting.solveGross(netWeth, sell, pool.baseFeeRemainder, pool.componentFeeRemainder);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyPoolManager();
        if (!_redeeming || keccak256(data) != _expectedRedeemHash) revert InvalidHookData();
        (bytes4 domain, address recipient, uint256 amount) = abi.decode(data, (bytes4, address, uint256));
        if (domain != REDEEM_DOMAIN || recipient == address(0) || amount == 0) revert InvalidHookData();
        manager.burn(address(this), uint160(address(weth)), amount);
        manager.take(Currency.wrap(address(weth)), recipient, amount);
        return "";
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (sender != registrar) revert OnlyRegistrar();
        PoolId poolId = key.toId();
        PoolState storage pool = _pools[poolId];
        if (!pool.registered) revert NotRegistered();
        if (pool.initialized) revert AlreadyInitialized();
        _validateRegisteredPool(key, pool);
        pool.initialized = true;
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_swapOpen || _redeeming) revert CallbackInProgress();
        PoolId poolId = key.toId();
        PoolState storage pool = _pools[poolId];
        _validateRegisteredPool(key, pool);
        if (!pool.initialized) revert NotInitialized();
        if (params.amountSpecified == 0) revert InvalidAmount();
        _swapOpen = true;

        PendingSwap memory current;
        current.poolId = poolId;
        current.subject = pool.subject;
        current.exactInputMode = params.amountSpecified < 0;
        (Currency specified, Currency unspecified) = _sortCurrencies(key, params);
        Currency input = current.exactInputMode ? specified : unspecified;
        current.sell = Currency.unwrap(input) == pool.subject;
        if (!current.sell && Currency.unwrap(input) != address(weth)) revert InvalidPool();
        current.wethSpecified = Currency.unwrap(specified) == address(weth);

        current = _applyHookData(sender, hookData, params, current);

        int128 specifiedDelta;
        if (current.wethSpecified) {
            uint256 gross;
            if (current.exactInputMode) {
                gross = _absoluteAmount(params.amountSpecified);
            } else {
                uint256 net = _absoluteAmount(params.amountSpecified);
                gross =
                    LooongAccounting.solveGross(net, current.sell, pool.baseFeeRemainder, pool.componentFeeRemainder);
                if (current.witnessGross != 0 && current.witnessGross != gross) revert InvalidWitness();
            }
            _requireGross(gross);
            (current.baseFee, current.componentFee) = _applyFees(gross, current.sell, pool);
            current.grossWeth = gross;
            uint256 totalFee = current.baseFee + current.componentFee;
            specifiedDelta = _toInt128(totalFee);
            current.expectedWethDelta = current.sell ? _toInt128(gross) : -_toInt128(gross - totalFee);
        }

        if (current.kind == SELL_INTENT) {
            _prepayPosition(current.positionId, current.owner, current.exactInput, pool.subject);
        }
        _pendingSwap = current;
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, 0), 0);
    }

    function _applyHookData(
        address sender,
        bytes calldata hookData,
        SwapParams calldata params,
        PendingSwap memory current
    ) private returns (PendingSwap memory) {
        if (hookData.length == 0) return current;
        if (hookData.length != 64) revert InvalidHookData();
        bytes4 domain = abi.decode(hookData[:32], (bytes4));
        if (domain == INTENT_DOMAIN) {
            if (!current.exactInputMode) revert UnsupportedExactOutput();
            return _claimIntent(sender, abi.decode(hookData[32:], (bytes32)), params, current);
        }
        if (domain == WITNESS_DOMAIN) {
            if (current.exactInputMode) revert InvalidWitness();
            current.witnessGross = abi.decode(hookData[32:], (uint256));
            if (current.witnessGross == 0) revert InvalidWitness();
            return current;
        }
        revert InvalidHookData();
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128 returnDelta)
    {
        if (!_swapOpen) revert CallbackInProgress();
        PendingSwap memory current = _pendingSwap;
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(current.poolId)) revert InvalidPool();
        PoolState storage pool = _pools[current.poolId];
        _validateRegisteredPool(key, pool);
        int128 wethDelta = Currency.unwrap(key.currency0) == address(weth) ? delta.amount0() : delta.amount1();

        if (current.wethSpecified) {
            if (wethDelta != current.expectedWethDelta) revert PartialFill();
        } else {
            uint256 gross;
            if (current.sell && current.exactInputMode) {
                if (wethDelta <= 0) revert PartialFill();
                gross = uint128(wethDelta);
            } else if (!current.sell && !current.exactInputMode) {
                if (wethDelta >= 0) revert PartialFill();
                uint256 poolInput = uint256(-int256(wethDelta));
                gross = LooongAccounting.solveGross(poolInput, false, pool.baseFeeRemainder, pool.componentFeeRemainder);
                if (current.witnessGross != 0 && current.witnessGross != gross) revert InvalidWitness();
            } else {
                revert InvalidPool();
            }
            _requireGross(gross);
            (current.baseFee, current.componentFee) = _applyFees(gross, current.sell, pool);
            current.grossWeth = gross;
            returnDelta = _toInt128(current.baseFee + current.componentFee);
        }

        if (current.kind == BUY_INTENT) {
            int128 baseDelta = Currency.unwrap(key.currency0) == current.subject ? delta.amount0() : delta.amount1();
            if (baseDelta <= 0 || uint128(baseDelta) < current.minimumOutput) revert PartialFill();
            uint128 tokens = uint128(baseDelta);
            manager.take(Currency.wrap(current.subject), address(this), tokens);
            returnDelta += _toInt128(tokens);
            _openPosition(current.positionId, current.owner, tokens, current.grossWeth, pool);
        } else if (current.kind == SELL_INTENT) {
            int128 baseDelta = Currency.unwrap(key.currency0) == current.subject ? delta.amount0() : delta.amount1();
            if (baseDelta >= 0 || uint256(-int256(baseDelta)) != current.exactInput) revert PartialFill();
            uint256 netOutput = current.grossWeth - current.baseFee - current.componentFee;
            if (netOutput < current.minimumOutput) revert PartialFill();
            _completePositionSell(current, pool);
        } else if (current.sell) {
            _distributeOrdinarySell(current.poolId, current.componentFee, pool);
        }

        if (current.intentId != bytes32(0)) delete intents[current.intentId];
        delete _pendingSwap;
        _swapOpen = false;
        _assertCustody(current.subject);
        _assertClaims();
        return (BaseHook.afterSwap.selector, returnDelta);
    }

    function _claimIntent(address sender, bytes32 intentId, SwapParams calldata params, PendingSwap memory current)
        private
        returns (PendingSwap memory)
    {
        if (sender != trustedRouter) revert OnlyRouter();
        Intent storage intent = intents[intentId];
        if (intent.owner == address(0)) revert InvalidIntent();
        if (intent.claimed) revert ReplayedIntent();
        if (PoolId.unwrap(intent.poolId) != PoolId.unwrap(current.poolId)) revert InvalidPool();
        if (block.timestamp > intent.deadline) revert ExpiredIntent();
        if (
            intent.zeroForOne != params.zeroForOne || -params.amountSpecified != int256(uint256(intent.amountIn))
                || intent.sqrtPriceLimitX96 != params.sqrtPriceLimitX96
        ) revert InvalidIntent();
        if ((intent.kind == BUY_INTENT) == current.sell) revert InvalidIntent();

        intent.claimed = true;
        current.intentId = intentId;
        current.owner = intent.owner;
        current.positionId = intent.positionId;
        current.exactInput = intent.amountIn;
        current.minimumOutput = intent.amountOutMinimum;
        current.kind = intent.kind;
        return current;
    }

    function _openPosition(uint256 positionId, address owner, uint128 tokens, uint256 basis, PoolState storage pool)
        private
    {
        if (positionId != nextPositionId || positions[positionId].owner != address(0)) revert InvalidIntent();
        positions[positionId] = Position({
            owner: owner,
            openedAt: uint64(block.timestamp),
            rewardActive: false,
            initialTokens: tokens,
            remainingTokens: tokens,
            soldTokens: 0,
            withdrawnTokens: 0,
            initialBasis: basis,
            remainingBasis: basis,
            soldBasis: 0,
            withdrawnBasis: 0,
            profitRemainder: 0
        });
        positionPools[positionId] = _pendingSwap.poolId;
        pool.totalCustodiedTokens += tokens;
        totalCustodiedByToken[pool.subject] += tokens;
        ++nextPositionId;
        emit PositionOpened(_pendingSwap.poolId, positionId, owner, tokens, basis);
    }

    function _completePositionSell(PendingSwap memory current, PoolState storage pool) private {
        Position storage position = positions[current.positionId];
        if (PoolId.unwrap(positionPools[current.positionId]) != PoolId.unwrap(current.poolId)) revert InvalidPool();
        if (position.owner != current.owner) revert NotPositionOwner();
        if (current.exactInput > position.remainingTokens) revert InsufficientPosition();

        address owner = position.owner;
        uint256 allocatedBasis = _reducePosition(position, current.exactInput, true, current.poolId, pool);
        pool.totalCustodiedTokens -= current.exactInput;
        totalCustodiedByToken[pool.subject] -= current.exactInput;

        uint256 eligibleProfit;
        if (current.grossWeth > current.baseFee + allocatedBasis) {
            eligibleProfit = current.grossWeth - current.baseFee - allocatedBasis;
        }
        uint256 maturityAt = uint256(position.openedAt) + MATURITY;
        uint256 timeRemaining = block.timestamp < maturityAt ? maturityAt - block.timestamp : 0;
        uint256 reward;
        if (pool.totalEligibleShares != _ownerShares[current.poolId][owner]) {
            uint256 nextRemainder;
            (reward, nextRemainder) = LooongAccounting.earlyProfitShare(
                eligibleProfit, timeRemaining, position.profitRemainder, current.componentFee
            );
            position.profitRemainder = nextRemainder;
        }
        uint256 rebate = current.componentFee - reward;
        if (rebate != 0) {
            _sellerRebates[current.poolId][owner] += rebate;
            pool.totalRebateLiability += rebate;
            totalRebateLiability += rebate;
        }
        if (reward != 0) {
            pool.totalScaledRewardLiability += reward * REWARD_PRECISION;
            totalScaledRewardLiability += reward * REWARD_PRECISION;
            _indexReward(current.poolId, reward * REWARD_PRECISION, owner, pool);
        }

        bool closed = position.remainingTokens == 0;
        if (closed) {
            delete positions[current.positionId];
            positionPools[current.positionId] = PoolId.wrap(bytes32(0));
        }
        _emitPositionSold(current, owner, allocatedBasis, rebate, reward);
    }

    function _emitPositionSold(
        PendingSwap memory current,
        address owner,
        uint256 allocatedBasis,
        uint256 rebate,
        uint256 reward
    ) private {
        emit PositionSold(
            current.poolId,
            current.positionId,
            owner,
            current.exactInput,
            allocatedBasis,
            current.grossWeth,
            rebate,
            reward
        );
    }

    function _reducePosition(
        Position storage position,
        uint128 amount,
        bool sold,
        PoolId poolId,
        PoolState storage pool
    ) private returns (uint256 allocatedBasis) {
        allocatedBasis = LooongAccounting.allocateBasis(position.remainingBasis, position.remainingTokens, amount);
        if (position.rewardActive) {
            _checkpoint(poolId, position.owner, pool);
            _ownerShares[poolId][position.owner] -= amount;
            pool.totalEligibleShares -= amount;
        }
        position.remainingTokens -= amount;
        position.remainingBasis -= allocatedBasis;
        if (sold) {
            position.soldTokens += amount;
            position.soldBasis += allocatedBasis;
        } else {
            position.withdrawnTokens += amount;
            position.withdrawnBasis += allocatedBasis;
        }
    }

    function _distributeOrdinarySell(PoolId poolId, uint256 componentFee, PoolState storage pool) private {
        if (componentFee == 0) return;
        pool.totalScaledRewardLiability += componentFee * REWARD_PRECISION;
        totalScaledRewardLiability += componentFee * REWARD_PRECISION;
        _indexReward(poolId, componentFee * REWARD_PRECISION, address(0), pool);
    }

    function _indexRewardDust(PoolId poolId, address excludedOwner, PoolState storage pool) private {
        if (pool.rewardDustScaled != 0) _indexReward(poolId, 0, excludedOwner, pool);
    }

    function _indexReward(PoolId poolId, uint256 newScaledReward, address excludedOwner, PoolState storage pool)
        private
    {
        if (excludedOwner != address(0)) _checkpoint(poolId, excludedOwner, pool);
        uint256 excludedShares = excludedOwner == address(0) ? 0 : _ownerShares[poolId][excludedOwner];
        uint256 eligibleShares = pool.totalEligibleShares - excludedShares;
        uint256 scaled = newScaledReward + pool.rewardDustScaled;
        if (eligibleShares == 0) {
            pool.rewardDustScaled = scaled;
            return;
        }
        uint256 increment = scaled / eligibleShares;
        pool.rewardDustScaled = scaled - increment * eligibleShares;
        pool.cumulativeRewardPerShare += increment;
        if (excludedOwner != address(0)) _ownerRewardIndex[poolId][excludedOwner] = pool.cumulativeRewardPerShare;
    }

    function _checkpoint(PoolId poolId, address owner, PoolState storage pool) private {
        uint256 currentIndex = pool.cumulativeRewardPerShare;
        uint256 previousIndex = _ownerRewardIndex[poolId][owner];
        if (currentIndex != previousIndex) {
            uint256 shares = _ownerShares[poolId][owner];
            if (shares != 0) _ownerScaledRewardCredit[poolId][owner] += shares * (currentIndex - previousIndex);
            _ownerRewardIndex[poolId][owner] = currentIndex;
        }
    }

    function _applyFees(uint256 gross, bool sell, PoolState storage pool)
        private
        returns (uint256 baseFee, uint256 componentFee)
    {
        uint256 nextBaseRemainder;
        (baseFee, nextBaseRemainder) =
            LooongAccounting.previewFee(gross, LooongAccounting.BASE_FEE_RATE, pool.baseFeeRemainder);
        pool.baseFeeRemainder = nextBaseRemainder;
        pool.baseFeeLiability += baseFee;
        totalBaseFeeLiability += baseFee;

        if (sell) {
            uint256 nextComponentRemainder;
            (componentFee, nextComponentRemainder) =
                LooongAccounting.previewFee(gross, LooongAccounting.SELL_COMPONENT_RATE, pool.componentFeeRemainder);
            pool.componentFeeRemainder = nextComponentRemainder;
        }
        manager.mint(address(this), uint160(address(weth)), baseFee + componentFee);
    }

    function _prepayPosition(uint256 positionId, address owner, uint128 amount, address subject) private {
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert PositionNotFound();
        if (position.owner != owner) revert NotPositionOwner();
        if (amount == 0 || amount > position.remainingTokens) revert InsufficientPosition();
        Currency base = Currency.wrap(subject);
        manager.sync(base);
        IERC20(subject).safeTransfer(address(manager), amount);
        if (manager.settleFor(trustedRouter) != amount) revert InvalidTokenTransfer();
    }

    function _transferBaseExact(address subject, address recipient, uint256 amount) private {
        IERC20 token = IERC20(subject);
        uint256 hookBefore = token.balanceOf(address(this));
        uint256 recipientBefore = token.balanceOf(recipient);
        token.safeTransfer(recipient, amount);
        if (
            hookBefore - token.balanceOf(address(this)) != amount
                || token.balanceOf(recipient) - recipientBefore != amount
        ) revert InvalidTokenTransfer();
    }

    function _redeemClaims(address recipient, uint256 amount) private {
        bytes memory data = abi.encode(REDEEM_DOMAIN, recipient, amount);
        _redeeming = true;
        _expectedRedeemHash = keccak256(data);
        if (manager.unlock(data).length != 0) revert InvalidHookData();
        _redeeming = false;
        delete _expectedRedeemHash;
        _assertClaims();
    }

    function _requireStage(PoolId poolId, address owner, uint128 amount, uint64 deadline) private view {
        _requireIdle();
        if (msg.sender != trustedRouter) revert OnlyRouter();
        if (!_pools[poolId].initialized) revert NotInitialized();
        if (owner == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (block.timestamp > deadline) revert ExpiredIntent();
    }

    function _requireIdle() private view {
        if (_swapOpen || _redeeming) revert CallbackInProgress();
    }

    function _validatePoolShape(PoolKey calldata key) private view returns (address subject) {
        if (
            address(key.hooks) != address(this) || key.fee != LP_FEE || key.tickSpacing != TICK_SPACING
                || Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)
        ) revert InvalidPool();
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (currency0 == address(weth)) subject = currency1;
        else if (currency1 == address(weth)) subject = currency0;
        else revert InvalidPool();
        if (subject == address(0) || subject == address(weth)) revert InvalidPool();
    }

    function _validateRegisteredPool(PoolKey calldata key, PoolState storage pool) private view {
        address subject = _validatePoolShape(key);
        if (!pool.registered || pool.subject != subject) revert InvalidPool();
    }

    function _registeredPool(PoolId poolId) private view returns (PoolState storage pool) {
        pool = _pools[poolId];
        if (!pool.registered) revert NotRegistered();
    }

    function _sortCurrencies(PoolKey calldata key, SwapParams calldata params)
        private
        pure
        returns (Currency specified, Currency unspecified)
    {
        return params.zeroForOne == (params.amountSpecified < 0)
            ? (key.currency0, key.currency1)
            : (key.currency1, key.currency0);
    }

    function _absoluteAmount(int256 amount) private pure returns (uint256 value) {
        value = amount < 0 ? uint256(-amount) : uint256(amount);
        if (value > uint256(uint128(type(int128).max))) revert AmountTooLarge();
    }

    function _toInt128(uint256 amount) private pure returns (int128) {
        if (amount > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        return int128(uint128(amount));
    }

    function _requireGross(uint256 gross) private pure {
        if (gross < MIN_GROSS_WETH) revert InvalidAmount();
    }

    function _assertCustody(address subject) private view {
        if (IERC20(subject).balanceOf(address(this)) < totalCustodiedByToken[subject]) revert AccountingInvariant();
    }

    function _assertClaims() private view {
        if (!claimsAreConserved()) revert AccountingInvariant();
    }
}
