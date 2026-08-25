// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ILooongHook} from "./interfaces/ILooongHook.sol";

/// @notice Authenticated settlement boundary for ordinary swaps and custodied positions.
contract LooongRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct SwapRequest {
        address payer;
        address recipient;
        bool zeroForOne;
        bool exactInput;
        bool skipBaseSettlement;
        uint128 amount;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    error AlreadyBound();
    error CallbackInProgress();
    error DeadlineExpired();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDelta();
    error InvalidPool();
    error InvalidUnlock();
    error NotBound();
    error OnlyBinder();
    error OnlyPoolManager();
    error SettlementMismatch(uint256 expected, uint256 actual);
    error SlippageExceeded();

    event RouterBound(address indexed looong, address indexed weth, address indexed hook);

    IPoolManager public immutable poolManager;
    address public immutable binder;

    IERC20 public looong;
    IERC20 public weth;
    ILooongHook public hook;
    bool public bound;

    bool private _unlocking;
    bytes32 private _expectedUnlockHash;

    constructor(IPoolManager manager, address binder_) {
        if (address(manager) == address(0) || binder_ == address(0)) revert InvalidAddress();
        poolManager = manager;
        binder = binder_;
    }

    function bind(IERC20 looong_, IERC20 weth_, ILooongHook hook_) external {
        if (msg.sender != binder) revert OnlyBinder();
        if (bound) revert AlreadyBound();
        if (
            address(looong_) == address(0) || address(weth_) == address(0) || address(hook_) == address(0)
                || address(looong_) == address(weth_)
        ) revert InvalidAddress();
        looong = looong_;
        weth = weth_;
        hook = hook_;
        bound = true;
        emit RouterBound(address(looong_), address(weth_), address(hook_));
    }

    function poolKey() public view returns (PoolKey memory key) {
        if (!bound) revert NotBound();
        (Currency currency0, Currency currency1) = address(looong) < address(weth)
            ? (Currency.wrap(address(looong)), Currency.wrap(address(weth)))
            : (Currency.wrap(address(weth)), Currency.wrap(address(looong)));
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3_000, tickSpacing: 60, hooks: IHooks(address(hook))
        });
    }

    function buy(uint128 wethAmountIn, uint128 looongAmountOutMinimum, uint160 sqrtPriceLimitX96, uint64 deadline)
        external
        nonReentrant
        returns (uint256 positionId)
    {
        _validateEntry(wethAmountIn, deadline);
        bool zeroForOne = address(weth) < address(looong);
        (bytes32 intentId, uint256 stagedPositionId) =
            hook.stageBuy(msg.sender, zeroForOne, wethAmountIn, looongAmountOutMinimum, sqrtPriceLimitX96, deadline);
        BalanceDelta delta = _swap(
            SwapRequest({
                payer: msg.sender,
                recipient: msg.sender,
                zeroForOne: zeroForOne,
                exactInput: true,
                skipBaseSettlement: false,
                amount: wethAmountIn,
                sqrtPriceLimitX96: sqrtPriceLimitX96,
                hookData: abi.encode(hook.INTENT_DOMAIN(), intentId)
            })
        );
        if (_deltaFor(delta, Currency.wrap(address(weth))) != -int256(uint256(wethAmountIn))) {
            revert InvalidDelta();
        }
        if (_deltaFor(delta, Currency.wrap(address(looong))) != 0) revert InvalidDelta();
        return stagedPositionId;
    }

    function sell(
        uint256 positionId,
        uint128 looongAmountIn,
        uint128 wethAmountOutMinimum,
        uint160 sqrtPriceLimitX96,
        uint64 deadline
    ) external nonReentrant returns (uint256 wethAmountOut) {
        _validateEntry(looongAmountIn, deadline);
        bool zeroForOne = address(looong) < address(weth);
        bytes32 intentId = hook.stageSell(
            msg.sender, positionId, zeroForOne, looongAmountIn, wethAmountOutMinimum, sqrtPriceLimitX96, deadline
        );
        BalanceDelta delta = _swap(
            SwapRequest({
                payer: msg.sender,
                recipient: msg.sender,
                zeroForOne: zeroForOne,
                exactInput: true,
                skipBaseSettlement: true,
                amount: looongAmountIn,
                sqrtPriceLimitX96: sqrtPriceLimitX96,
                hookData: abi.encode(hook.INTENT_DOMAIN(), intentId)
            })
        );
        if (_deltaFor(delta, Currency.wrap(address(looong))) != -int256(uint256(looongAmountIn))) {
            revert InvalidDelta();
        }
        int256 outputDelta = _deltaFor(delta, Currency.wrap(address(weth)));
        if (outputDelta <= 0) revert InvalidDelta();
        wethAmountOut = uint256(outputDelta);
        if (wethAmountOut < wethAmountOutMinimum) revert SlippageExceeded();
    }

    function swapExactInput(
        bool buyLooong,
        uint128 amountIn,
        uint128 amountOutMinimum,
        address recipient,
        uint160 sqrtPriceLimitX96,
        uint64 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        _validateOrdinaryEntry(amountIn, recipient, deadline);
        Currency input = Currency.wrap(buyLooong ? address(weth) : address(looong));
        Currency output = Currency.wrap(buyLooong ? address(looong) : address(weth));
        BalanceDelta delta = _swap(
            SwapRequest({
                payer: msg.sender,
                recipient: recipient,
                zeroForOne: Currency.unwrap(input) < Currency.unwrap(output),
                exactInput: true,
                skipBaseSettlement: false,
                amount: amountIn,
                sqrtPriceLimitX96: sqrtPriceLimitX96,
                hookData: ""
            })
        );
        uint256 actualInput = _debt(_deltaFor(delta, input));
        amountOut = _credit(_deltaFor(delta, output));
        if (actualInput != amountIn || amountOut < amountOutMinimum) revert SlippageExceeded();
    }

    function swapExactOutput(
        bool buyLooong,
        uint128 amountOut,
        uint128 amountInMaximum,
        address recipient,
        uint160 sqrtPriceLimitX96,
        uint64 deadline,
        bytes calldata witness
    ) external nonReentrant returns (uint256 amountIn) {
        _validateOrdinaryEntry(amountOut, recipient, deadline);
        if (amountInMaximum == 0) revert InvalidAmount();
        Currency input = Currency.wrap(buyLooong ? address(weth) : address(looong));
        Currency output = Currency.wrap(buyLooong ? address(looong) : address(weth));
        BalanceDelta delta = _swap(
            SwapRequest({
                payer: msg.sender,
                recipient: recipient,
                zeroForOne: Currency.unwrap(input) < Currency.unwrap(output),
                exactInput: false,
                skipBaseSettlement: false,
                amount: amountOut,
                sqrtPriceLimitX96: sqrtPriceLimitX96,
                hookData: witness
            })
        );
        amountIn = _debt(_deltaFor(delta, input));
        uint256 actualOutput = _credit(_deltaFor(delta, output));
        if (amountIn > amountInMaximum || actualOutput != amountOut) revert SlippageExceeded();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (!_unlocking || keccak256(data) != _expectedUnlockHash) revert InvalidUnlock();
        SwapRequest memory request = abi.decode(data, (SwapRequest));
        PoolKey memory key = poolKey();
        int256 specified = request.exactInput ? -int256(uint256(request.amount)) : int256(uint256(request.amount));
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: request.zeroForOne, amountSpecified: specified, sqrtPriceLimitX96: request.sqrtPriceLimitX96
            }),
            request.hookData
        );

        _resolve(key.currency0, request, delta.amount0());
        _resolve(key.currency1, request, delta.amount1());
        return abi.encode(delta);
    }

    function _swap(SwapRequest memory request) private returns (BalanceDelta delta) {
        if (_unlocking) revert CallbackInProgress();
        bytes memory data = abi.encode(request);
        _unlocking = true;
        _expectedUnlockHash = keccak256(data);
        delta = abi.decode(poolManager.unlock(data), (BalanceDelta));
        _unlocking = false;
        delete _expectedUnlockHash;
    }

    function _resolve(Currency currency, SwapRequest memory request, int128 delta) private {
        if (request.skipBaseSettlement && Currency.unwrap(currency) == address(looong)) return;
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            poolManager.sync(currency);
            // The public entry point fixes payer to msg.sender. The unlock payload is hash-bound.
            // slither-disable-next-line arbitrary-send-erc20
            IERC20(Currency.unwrap(currency)).safeTransferFrom(request.payer, address(poolManager), amount);
            uint256 settled = poolManager.settle();
            if (settled != amount) revert SettlementMismatch(amount, settled);
        } else if (delta > 0) {
            poolManager.take(currency, request.recipient, uint128(delta));
        }
    }

    function _validateEntry(uint128 amount, uint64 deadline) private view {
        if (!bound) revert NotBound();
        if (amount == 0) revert InvalidAmount();
        if (block.timestamp > deadline) revert DeadlineExpired();
    }

    function _validateOrdinaryEntry(uint128 amount, address recipient, uint64 deadline) private view {
        _validateEntry(amount, deadline);
        if (recipient == address(0)) revert InvalidAddress();
    }

    function _deltaFor(BalanceDelta delta, Currency currency) private view returns (int256) {
        PoolKey memory key = poolKey();
        if (currency == key.currency0) return delta.amount0();
        if (currency == key.currency1) return delta.amount1();
        revert InvalidPool();
    }

    function _debt(int256 amount) private pure returns (uint256) {
        if (amount >= 0) revert InvalidDelta();
        return uint256(-amount);
    }

    function _credit(int256 amount) private pure returns (uint256) {
        if (amount <= 0) revert InvalidDelta();
        return uint256(amount);
    }
}
