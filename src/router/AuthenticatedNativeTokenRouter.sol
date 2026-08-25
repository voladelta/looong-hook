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

/// @notice Replaceable single-pool router seed with authenticated payer/recipient hook context.
contract AuthenticatedNativeTokenRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes4 public constant ROUTE_DOMAIN = bytes4(keccak256("V4HOOK_NATIVE_TOKEN_SWAP_V1"));

    struct SwapRequest {
        address payer;
        address recipient;
        bool buy;
        bool exactInput;
        uint128 amount;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    error AlreadyBound();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDelta();
    error InvalidNativeValue(uint256 supplied, uint256 required);
    error NativeTransferFailed();
    error NotBound();
    error OnlyBinder();
    error OnlyPoolManager();
    error SettlementMismatch(uint256 expected, uint256 actual);
    error SlippageExceeded();

    event RouterBound(address indexed token, address indexed hook, uint24 lpFee, int24 tickSpacing);
    event NativeSurplusSwept(address indexed recipient, uint256 amount);

    IPoolManager public immutable poolManager;
    address public immutable binder;
    address payable public immutable surplusRecipient;

    Currency public token;
    IHooks public hook;
    uint24 public lpFee;
    int24 public tickSpacing;
    bool public bound;

    constructor(IPoolManager manager, address binder_, address payable surplusRecipient_) {
        if (address(manager) == address(0) || binder_ == address(0) || surplusRecipient_ == address(0)) {
            revert InvalidAddress();
        }
        poolManager = manager;
        binder = binder_;
        surplusRecipient = surplusRecipient_;
    }

    /// @notice Binds the long-lived router once from an atomic launch factory or deployment owner.
    function bind(Currency token_, IHooks hook_, uint24 lpFee_, int24 tickSpacing_) external {
        if (msg.sender != binder) revert OnlyBinder();
        if (bound) revert AlreadyBound();
        if (Currency.unwrap(token_) == address(0) || address(hook_) == address(0)) revert InvalidAddress();

        token = token_;
        hook = hook_;
        lpFee = lpFee_;
        tickSpacing = tickSpacing_;
        bound = true;
        emit RouterBound(Currency.unwrap(token_), address(hook_), lpFee_, tickSpacing_);
    }

    function poolKey() public view returns (PoolKey memory) {
        if (!bound) revert NotBound();
        return PoolKey({
            currency0: Currency.wrap(address(0)), currency1: token, fee: lpFee, tickSpacing: tickSpacing, hooks: hook
        });
    }

    function swapExactInput(
        bool buy,
        uint128 amountInMaximum,
        uint128 amountOutMinimum,
        address recipient,
        uint160 sqrtPriceLimitX96,
        bytes calldata productHookData
    ) external payable nonReentrant returns (uint256 amountIn, uint256 amountOut) {
        _validateEntry(buy, amountInMaximum, recipient);
        BalanceDelta delta = _swap(
            SwapRequest({
                payer: msg.sender,
                recipient: recipient,
                buy: buy,
                exactInput: true,
                amount: amountInMaximum,
                sqrtPriceLimitX96: sqrtPriceLimitX96,
                hookData: productHookData
            })
        );

        amountIn = buy ? _debt(delta.amount0()) : _debt(delta.amount1());
        amountOut = buy ? _credit(delta.amount1()) : _credit(delta.amount0());
        if (amountIn > amountInMaximum || amountOut < amountOutMinimum) revert SlippageExceeded();
        _refundCurrentCall(buy, amountInMaximum, amountIn);
    }

    function swapExactOutput(
        bool buy,
        uint128 amountOut,
        uint128 amountInMaximum,
        address recipient,
        uint160 sqrtPriceLimitX96,
        bytes calldata productHookData
    ) external payable nonReentrant returns (uint256 amountIn) {
        if (amountOut == 0) revert InvalidAmount();
        _validateEntry(buy, amountInMaximum, recipient);
        BalanceDelta delta = _swap(
            SwapRequest({
                payer: msg.sender,
                recipient: recipient,
                buy: buy,
                exactInput: false,
                amount: amountOut,
                sqrtPriceLimitX96: sqrtPriceLimitX96,
                hookData: productHookData
            })
        );

        amountIn = buy ? _debt(delta.amount0()) : _debt(delta.amount1());
        uint256 actualOut = buy ? _credit(delta.amount1()) : _credit(delta.amount0());
        if (amountIn > amountInMaximum || actualOut != amountOut) revert SlippageExceeded();
        _refundCurrentCall(buy, amountInMaximum, amountIn);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        SwapRequest memory request = abi.decode(data, (SwapRequest));
        PoolKey memory key = poolKey();
        int256 specified = request.exactInput ? -int256(uint256(request.amount)) : int256(uint256(request.amount));
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: request.buy, amountSpecified: specified, sqrtPriceLimitX96: request.sqrtPriceLimitX96
            }),
            abi.encode(ROUTE_DOMAIN, request.payer, request.recipient, request.hookData)
        );

        _resolve(key.currency0, request.payer, request.recipient, delta.amount0());
        _resolve(key.currency1, request.payer, request.recipient, delta.amount1());
        return abi.encode(delta);
    }

    /// @notice Sends only balance that survived completed calls or was forced into the router.
    function sweepForcedNative() external nonReentrant returns (uint256 amount) {
        amount = address(this).balance;
        // A zero balance is ordinary idempotent cleanup, not an externally controlled threshold.
        // slither-disable-next-line incorrect-equality
        if (amount == 0) return 0;
        // The immutable recipient is constructor-bound and cannot be selected by the caller.
        // slither-disable-next-line low-level-calls
        (bool sent,) = surplusRecipient.call{value: amount}("");
        if (!sent) revert NativeTransferFailed();
        emit NativeSurplusSwept(surplusRecipient, amount);
    }

    function _swap(SwapRequest memory request) private returns (BalanceDelta delta) {
        delta = abi.decode(poolManager.unlock(abi.encode(request)), (BalanceDelta));
    }

    function _resolve(Currency currency, address payer, address recipient, int128 delta) private {
        if (delta < 0) {
            uint256 amount = uint256(uint128(-delta));
            poolManager.sync(currency);
            if (Currency.unwrap(currency) == address(0)) {
                uint256 settled = poolManager.settle{value: amount}();
                if (settled != amount) revert SettlementMismatch(amount, settled);
            } else {
                // `payer` is captured from msg.sender by a nonReentrant entry point before unlock.
                // slither-disable-next-line arbitrary-send-erc20
                IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(poolManager), amount);
                uint256 settled = poolManager.settle();
                if (settled != amount) revert SettlementMismatch(amount, settled);
            }
        } else if (delta > 0) {
            poolManager.take(currency, recipient, uint256(uint128(delta)));
        }
    }

    function _validateEntry(bool buy, uint128 amount, address recipient) private view {
        if (!bound) revert NotBound();
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidAddress();
        uint256 required = buy ? amount : 0;
        if (msg.value != required) revert InvalidNativeValue(msg.value, required);
    }

    function _refundCurrentCall(bool buy, uint256 supplied, uint256 used) private {
        if (!buy || supplied == used) return;
        // The amount is derived only from this call's value and observed PoolManager debt.
        // slither-disable-next-line arbitrary-send-eth,low-level-calls
        (bool refunded,) = msg.sender.call{value: supplied - used}("");
        if (!refunded) revert NativeTransferFailed();
    }

    function _debt(int128 amount) private pure returns (uint256) {
        if (amount > 0) revert InvalidDelta();
        return uint256(-int256(amount));
    }

    function _credit(int128 amount) private pure returns (uint256) {
        if (amount < 0) revert InvalidDelta();
        return uint256(uint128(amount));
    }
}
