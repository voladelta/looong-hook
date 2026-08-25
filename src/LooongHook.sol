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

/// @notice Immutable accounting and custody hook for one LOOONG/WETH pool.
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

    event PoolRegistered(PoolId indexed poolId);
    event PositionOpened(uint256 indexed positionId, address indexed owner, uint256 tokens, uint256 wethBasis);
    event PositionSold(
        uint256 indexed positionId,
        address indexed owner,
        uint256 tokens,
        uint256 wethBasis,
        uint256 grossWeth,
        uint256 rebate,
        uint256 reward
    );
    event PositionWithdrawn(uint256 indexed positionId, address indexed owner, uint256 tokens, uint256 wethBasis);
    event PositionActivated(uint256 indexed positionId, address indexed owner, uint256 shares);
    event BaseFeesClaimed(address indexed recipient, uint256 amount);
    event RebateClaimed(address indexed seller, uint256 amount);
    event RewardsClaimed(address indexed owner, address indexed recipient, uint256 amount);

    IPoolManager public immutable manager;
    address public immutable registrar;
    address public immutable trustedRouter;
    IERC20 public immutable looong;
    IERC20 public immutable weth;
    address public immutable feeBeneficiary;

    PoolId public canonicalPoolId;
    bool public registered;
    bool public initialized;
    uint256 public nextPositionId = 1;
    uint256 public totalCustodiedTokens;

    uint256 public baseFeeRemainder;
    uint256 public componentFeeRemainder;
    uint256 public baseFeeLiability;
    uint256 public totalRebateLiability;
    uint256 public totalScaledRewardLiability;

    uint256 public cumulativeRewardPerShare;
    uint256 public rewardDustScaled;
    uint256 public totalEligibleShares;

    mapping(uint256 positionId => Position) public positions;
    mapping(address owner => uint64 nonce) public ownerNonces;
    mapping(bytes32 intentId => Intent) public intents;
    mapping(address seller => uint256 amount) public sellerRebates;
    mapping(address owner => uint256 shares) public ownerShares;
    mapping(address owner => uint256 index) public ownerRewardIndex;
    mapping(address owner => uint256 scaledCredit) public ownerScaledRewardCredit;

    PendingSwap private _pendingSwap;
    bool private _swapOpen;
    bool private _redeeming;
    bytes32 private _expectedRedeemHash;

    constructor(
        IPoolManager manager_,
        address registrar_,
        address trustedRouter_,
        IERC20 looong_,
        IERC20 weth_,
        address feeBeneficiary_
    ) BaseHook(manager_) {
        if (
            address(manager_) == address(0) || registrar_ == address(0) || trustedRouter_ == address(0)
                || address(looong_) == address(0) || address(weth_) == address(0) || feeBeneficiary_ == address(0)
                || address(looong_) == address(weth_)
        ) revert InvalidAddress();
        manager = manager_;
        registrar = registrar_;
        trustedRouter = trustedRouter_;
        looong = looong_;
        weth = weth_;
        feeBeneficiary = feeBeneficiary_;
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

    function registerPool(PoolKey calldata key) external nonReentrant {
        _requireIdle();
        if (msg.sender != registrar) revert OnlyRegistrar();
        if (registered) revert AlreadyRegistered();
        _validatePoolShape(key);
        canonicalPoolId = key.toId();
        registered = true;
        emit PoolRegistered(canonicalPoolId);
    }

    function stageBuy(
        address owner,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        uint160 sqrtPriceLimitX96,
        uint64 deadline
    ) external nonReentrant returns (bytes32 intentId, uint256 positionId) {
        _requireStage(owner, amountIn, deadline);
        positionId = nextPositionId;
        uint64 nonce = ownerNonces[owner]++;
        intentId = keccak256(
            abi.encode(
                INTENT_DOMAIN,
                block.chainid,
                address(this),
                canonicalPoolId,
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
            poolId: canonicalPoolId,
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
        address owner,
        uint256 positionId,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        uint160 sqrtPriceLimitX96,
        uint64 deadline
    ) external nonReentrant returns (bytes32 intentId) {
        _requireStage(owner, amountIn, deadline);
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert PositionNotFound();
        if (position.owner != owner) revert NotPositionOwner();
        if (amountIn > position.remainingTokens) revert InsufficientPosition();
        uint64 nonce = ownerNonces[owner]++;
        intentId = keccak256(
            abi.encode(
                INTENT_DOMAIN,
                block.chainid,
                address(this),
                canonicalPoolId,
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
            poolId: canonicalPoolId,
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

    function activatePosition(uint256 positionId) external nonReentrant {
        _requireIdle();
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert PositionNotFound();
        if (block.timestamp < uint256(position.openedAt) + MATURITY) revert NotMature();
        if (position.rewardActive) return;

        _checkpoint(position.owner);
        position.rewardActive = true;
        ownerShares[position.owner] += position.remainingTokens;
        totalEligibleShares += position.remainingTokens;
        _indexRewardDust(address(0));
        emit PositionActivated(positionId, position.owner, position.remainingTokens);
    }

    function withdraw(uint256 positionId, uint128 amount) external nonReentrant {
        _requireIdle();
        if (amount == 0) revert InvalidAmount();
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert PositionNotFound();
        if (position.owner != msg.sender) revert NotPositionOwner();
        if (amount > position.remainingTokens) revert InsufficientPosition();

        address owner = position.owner;
        uint256 basis = _reducePosition(position, amount, false);
        totalCustodiedTokens -= amount;
        if (position.remainingTokens == 0) delete positions[positionId];
        _transferBaseExact(owner, amount);
        emit PositionWithdrawn(positionId, owner, amount, basis);
        _assertCustody();
    }

    function claimBaseFees(address recipient) external nonReentrant returns (uint256 amount) {
        _requireIdle();
        if (msg.sender != feeBeneficiary) revert OnlyBeneficiary();
        if (recipient == address(0)) revert InvalidRecipient();
        amount = baseFeeLiability;
        if (amount == 0) revert ClaimUnavailable();
        baseFeeLiability = 0;
        _redeemClaims(recipient, amount);
        emit BaseFeesClaimed(recipient, amount);
    }

    function claimRebate(address seller) external nonReentrant returns (uint256 amount) {
        _requireIdle();
        if (seller == address(0)) revert InvalidRecipient();
        amount = sellerRebates[seller];
        if (amount == 0) revert ClaimUnavailable();
        sellerRebates[seller] = 0;
        totalRebateLiability -= amount;
        _redeemClaims(seller, amount);
        emit RebateClaimed(seller, amount);
    }

    function claimRewards(address recipient) external nonReentrant returns (uint256 amount) {
        _requireIdle();
        if (recipient == address(0)) revert InvalidRecipient();
        _checkpoint(msg.sender);
        uint256 scaledCredit = ownerScaledRewardCredit[msg.sender];
        amount = scaledCredit / REWARD_PRECISION;
        if (amount == 0) revert ClaimUnavailable();
        uint256 claimedScaled = amount * REWARD_PRECISION;
        ownerScaledRewardCredit[msg.sender] = scaledCredit - claimedScaled;
        totalScaledRewardLiability -= claimedScaled;
        _redeemClaims(recipient, amount);
        emit RewardsClaimed(msg.sender, recipient, amount);
    }

    function quoteExactOutputGross(uint256 netWeth, bool sell) external view returns (uint256) {
        return LooongAccounting.solveGross(netWeth, sell, baseFeeRemainder, componentFeeRemainder);
    }

    function accountedWethClaims() public view returns (uint256) {
        return manager.balanceOf(address(this), uint160(address(weth)));
    }

    function accountingLiabilityScaled() public view returns (uint256) {
        return (baseFeeLiability + totalRebateLiability) * REWARD_PRECISION + totalScaledRewardLiability;
    }

    function custodyIsSolvent() external view returns (bool) {
        return looong.balanceOf(address(this)) >= totalCustodiedTokens;
    }

    function claimsAreConserved() external view returns (bool) {
        return accountedWethClaims() * REWARD_PRECISION == accountingLiabilityScaled();
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
        if (!registered) revert NotRegistered();
        if (initialized) revert AlreadyInitialized();
        _validateCanonicalPool(key);
        initialized = true;
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_swapOpen || _redeeming) revert CallbackInProgress();
        if (!initialized) revert NotInitialized();
        _validateCanonicalPool(key);
        if (params.amountSpecified == 0) revert InvalidAmount();
        _swapOpen = true;

        PendingSwap memory current;
        current.exactInputMode = params.amountSpecified < 0;
        (Currency specified, Currency unspecified) = _sortCurrencies(key, params);
        Currency input = current.exactInputMode ? specified : unspecified;
        current.sell = Currency.unwrap(input) == address(looong);
        if (!current.sell && Currency.unwrap(input) != address(weth)) revert InvalidPool();
        current.wethSpecified = Currency.unwrap(specified) == address(weth);

        if (hookData.length != 0) {
            if (hookData.length != 64) revert InvalidHookData();
            bytes4 domain = abi.decode(hookData[:32], (bytes4));
            if (domain == INTENT_DOMAIN) {
                if (!current.exactInputMode) revert UnsupportedExactOutput();
                bytes32 intentId = abi.decode(hookData[32:], (bytes32));
                current = _claimIntent(sender, intentId, params, current);
            } else if (domain == WITNESS_DOMAIN) {
                if (current.exactInputMode) revert InvalidWitness();
                current.witnessGross = abi.decode(hookData[32:], (uint256));
                if (current.witnessGross == 0) revert InvalidWitness();
            } else {
                revert InvalidHookData();
            }
        }

        int128 specifiedDelta;
        if (current.wethSpecified) {
            uint256 gross;
            if (current.exactInputMode) {
                gross = _absoluteAmount(params.amountSpecified);
            } else {
                uint256 net = _absoluteAmount(params.amountSpecified);
                gross = LooongAccounting.solveGross(net, current.sell, baseFeeRemainder, componentFeeRemainder);
                if (current.witnessGross != 0 && current.witnessGross != gross) revert InvalidWitness();
            }
            _requireGross(gross);
            (current.baseFee, current.componentFee) = _applyFees(gross, current.sell);
            current.grossWeth = gross;
            uint256 totalFee = current.baseFee + current.componentFee;
            specifiedDelta = _toInt128(totalFee);
            current.expectedWethDelta = current.sell ? _toInt128(gross) : -_toInt128(gross - totalFee);
        }

        if (current.kind == SELL_INTENT) _prepayPosition(current.positionId, current.owner, current.exactInput);
        _pendingSwap = current;
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, 0), 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128 returnDelta)
    {
        if (!_swapOpen) revert CallbackInProgress();
        _validateCanonicalPool(key);
        PendingSwap memory current = _pendingSwap;
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
                gross = LooongAccounting.solveGross(poolInput, false, baseFeeRemainder, componentFeeRemainder);
                if (current.witnessGross != 0 && current.witnessGross != gross) revert InvalidWitness();
            } else {
                revert InvalidPool();
            }
            _requireGross(gross);
            (current.baseFee, current.componentFee) = _applyFees(gross, current.sell);
            current.grossWeth = gross;
            returnDelta = _toInt128(current.baseFee + current.componentFee);
        }

        if (current.kind == BUY_INTENT) {
            int128 baseDelta = Currency.unwrap(key.currency0) == address(looong) ? delta.amount0() : delta.amount1();
            if (baseDelta <= 0 || uint128(baseDelta) < current.minimumOutput) revert PartialFill();
            uint128 tokens = uint128(baseDelta);
            manager.take(Currency.wrap(address(looong)), address(this), tokens);
            returnDelta += _toInt128(tokens);
            _openPosition(current.positionId, current.owner, tokens, current.grossWeth);
        } else if (current.kind == SELL_INTENT) {
            int128 baseDelta = Currency.unwrap(key.currency0) == address(looong) ? delta.amount0() : delta.amount1();
            if (baseDelta >= 0 || uint256(-int256(baseDelta)) != current.exactInput) revert PartialFill();
            uint256 netOutput = current.grossWeth - current.baseFee - current.componentFee;
            if (netOutput < current.minimumOutput) revert PartialFill();
            _completePositionSell(current);
        } else if (current.sell) {
            _distributeOrdinarySell(current.componentFee);
        }

        if (current.intentId != bytes32(0)) delete intents[current.intentId];
        delete _pendingSwap;
        _swapOpen = false;
        _assertCustody();
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
        if (PoolId.unwrap(intent.poolId) != PoolId.unwrap(canonicalPoolId)) revert InvalidPool();
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

    function _openPosition(uint256 positionId, address owner, uint128 tokens, uint256 basis) private {
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
        totalCustodiedTokens += tokens;
        ++nextPositionId;
        emit PositionOpened(positionId, owner, tokens, basis);
    }

    function _completePositionSell(PendingSwap memory current) private {
        Position storage position = positions[current.positionId];
        if (position.owner != current.owner) revert NotPositionOwner();
        if (current.exactInput > position.remainingTokens) revert InsufficientPosition();

        address owner = position.owner;
        uint256 allocatedBasis = _reducePosition(position, current.exactInput, true);
        totalCustodiedTokens -= current.exactInput;

        uint256 eligibleProfit;
        if (current.grossWeth > current.baseFee + allocatedBasis) {
            eligibleProfit = current.grossWeth - current.baseFee - allocatedBasis;
        }
        uint256 maturityAt = uint256(position.openedAt) + MATURITY;
        uint256 timeRemaining = block.timestamp < maturityAt ? maturityAt - block.timestamp : 0;
        uint256 reward;
        if (totalEligibleShares != ownerShares[owner]) {
            uint256 nextRemainder;
            (reward, nextRemainder) = LooongAccounting.earlyProfitShare(
                eligibleProfit, timeRemaining, position.profitRemainder, current.componentFee
            );
            position.profitRemainder = nextRemainder;
        }
        uint256 rebate = current.componentFee - reward;
        if (rebate != 0) {
            sellerRebates[owner] += rebate;
            totalRebateLiability += rebate;
        }
        if (reward != 0) {
            totalScaledRewardLiability += reward * REWARD_PRECISION;
            _indexReward(reward * REWARD_PRECISION, owner);
        }

        bool closed = position.remainingTokens == 0;
        if (closed) delete positions[current.positionId];
        emit PositionSold(
            current.positionId, owner, current.exactInput, allocatedBasis, current.grossWeth, rebate, reward
        );
    }

    function _reducePosition(Position storage position, uint128 amount, bool sold)
        private
        returns (uint256 allocatedBasis)
    {
        allocatedBasis = LooongAccounting.allocateBasis(position.remainingBasis, position.remainingTokens, amount);
        if (position.rewardActive) {
            _checkpoint(position.owner);
            ownerShares[position.owner] -= amount;
            totalEligibleShares -= amount;
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

    function _distributeOrdinarySell(uint256 componentFee) private {
        if (componentFee == 0) return;
        totalScaledRewardLiability += componentFee * REWARD_PRECISION;
        _indexReward(componentFee * REWARD_PRECISION, address(0));
    }

    function _indexRewardDust(address excludedOwner) private {
        if (rewardDustScaled != 0) _indexReward(0, excludedOwner);
    }

    function _indexReward(uint256 newScaledReward, address excludedOwner) private {
        if (excludedOwner != address(0)) _checkpoint(excludedOwner);
        uint256 excludedShares = excludedOwner == address(0) ? 0 : ownerShares[excludedOwner];
        uint256 eligibleShares = totalEligibleShares - excludedShares;
        uint256 scaled = newScaledReward + rewardDustScaled;
        if (eligibleShares == 0) {
            rewardDustScaled = scaled;
            return;
        }
        uint256 increment = scaled / eligibleShares;
        rewardDustScaled = scaled - increment * eligibleShares;
        cumulativeRewardPerShare += increment;
        if (excludedOwner != address(0)) ownerRewardIndex[excludedOwner] = cumulativeRewardPerShare;
    }

    function _checkpoint(address owner) private {
        uint256 currentIndex = cumulativeRewardPerShare;
        uint256 previousIndex = ownerRewardIndex[owner];
        if (currentIndex != previousIndex) {
            uint256 shares = ownerShares[owner];
            if (shares != 0) ownerScaledRewardCredit[owner] += shares * (currentIndex - previousIndex);
            ownerRewardIndex[owner] = currentIndex;
        }
    }

    function _applyFees(uint256 gross, bool sell) private returns (uint256 baseFee, uint256 componentFee) {
        uint256 nextBaseRemainder;
        (baseFee, nextBaseRemainder) =
            LooongAccounting.previewFee(gross, LooongAccounting.BASE_FEE_RATE, baseFeeRemainder);
        baseFeeRemainder = nextBaseRemainder;
        baseFeeLiability += baseFee;

        if (sell) {
            uint256 nextComponentRemainder;
            (componentFee, nextComponentRemainder) =
                LooongAccounting.previewFee(gross, LooongAccounting.SELL_COMPONENT_RATE, componentFeeRemainder);
            componentFeeRemainder = nextComponentRemainder;
        }
        manager.mint(address(this), uint160(address(weth)), baseFee + componentFee);
    }

    function _prepayPosition(uint256 positionId, address owner, uint128 amount) private {
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert PositionNotFound();
        if (position.owner != owner) revert NotPositionOwner();
        if (amount == 0 || amount > position.remainingTokens) revert InsufficientPosition();
        Currency base = Currency.wrap(address(looong));
        manager.sync(base);
        looong.safeTransfer(address(manager), amount);
        if (manager.settleFor(trustedRouter) != amount) revert InvalidTokenTransfer();
    }

    function _transferBaseExact(address recipient, uint256 amount) private {
        uint256 hookBefore = looong.balanceOf(address(this));
        uint256 recipientBefore = looong.balanceOf(recipient);
        looong.safeTransfer(recipient, amount);
        if (
            hookBefore - looong.balanceOf(address(this)) != amount
                || looong.balanceOf(recipient) - recipientBefore != amount
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

    function _requireStage(address owner, uint128 amount, uint64 deadline) private view {
        _requireIdle();
        if (msg.sender != trustedRouter) revert OnlyRouter();
        if (!initialized) revert NotInitialized();
        if (owner == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (block.timestamp > deadline) revert ExpiredIntent();
    }

    function _requireIdle() private view {
        if (_swapOpen || _redeeming) revert CallbackInProgress();
    }

    function _validatePoolShape(PoolKey calldata key) private view {
        if (
            address(key.hooks) != address(this) || key.fee != LP_FEE || key.tickSpacing != TICK_SPACING
                || Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)
        ) revert InvalidPool();
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (!((currency0 == address(looong) && currency1 == address(weth))
                    || (currency0 == address(weth) && currency1 == address(looong)))) revert InvalidPool();
    }

    function _validateCanonicalPool(PoolKey calldata key) private view {
        _validatePoolShape(key);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(canonicalPoolId)) revert InvalidPool();
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

    function _assertCustody() private view {
        if (looong.balanceOf(address(this)) < totalCustodiedTokens) revert AccountingInvariant();
    }

    function _assertClaims() private view {
        if (accountedWethClaims() * REWARD_PRECISION != accountingLiabilityScaled()) {
            revert AccountingInvariant();
        }
    }
}
