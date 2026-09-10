// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LooongHook} from "../../src/LooongHook.sol";

/// @dev Expected fees use lifetime notionals and the specified 1/1000 + 29/1000 rates.
/// No production accounting library, liability change or quote supplies an expectation.
abstract contract PoolSwapFeeOracle is Test {
    using PoolIdLibrary for PoolKey;

    struct FeeTotals {
        uint256 gross;
        uint256 soldGross;
        uint256 unclaimedBase;
    }

    struct FeeObservation {
        address subject;
        address wethAccount;
        address subjectAccount;
        uint256 wethBalance;
        uint256 subjectBalance;
        uint256 claims;
        uint256 baseLiability;
        uint256 rebateLiability;
        uint256 rewardLiability;
    }

    struct SwapFees {
        uint256 gross;
        uint256 base;
        uint256 component;
        uint256 subjectAmount;
    }

    mapping(PoolId => FeeTotals) internal feeTotals;

    function _observeFees(LooongHook hook, address subject, address wethAccount, address subjectAccount)
        internal
        returns (FeeObservation memory beforeSwap)
    {
        beforeSwap = FeeObservation({
            subject: subject,
            wethAccount: wethAccount,
            subjectAccount: subjectAccount,
            wethBalance: hook.weth().balanceOf(wethAccount),
            subjectBalance: IERC20(subject).balanceOf(subjectAccount),
            claims: hook.manager().balanceOf(address(hook), uint160(address(hook.weth()))),
            baseLiability: hook.totalBaseFeeLiability(),
            rebateLiability: hook.totalRebateLiability(),
            rewardLiability: hook.totalScaledRewardLiability()
        });
        vm.recordLogs();
    }

    function _assertSwapFees(LooongHook hook, PoolKey memory key, bool buy, FeeObservation memory beforeSwap)
        internal
        returns (SwapFees memory expected)
    {
        (int128 wethDelta, int128 subjectDelta) = _executedDeltas(hook, key);
        if (buy) {
            assertLt(wethDelta, 0, "PoolManager buy WETH delta");
            assertGt(subjectDelta, 0, "PoolManager buy subject delta");
            expected.gross = beforeSwap.wethBalance - hook.weth().balanceOf(beforeSwap.wethAccount);
            expected.subjectAmount = uint128(subjectDelta);
            assertEq(
                IERC20(beforeSwap.subject).balanceOf(beforeSwap.subjectAccount) - beforeSwap.subjectBalance,
                expected.subjectAmount,
                "buy recipient/custody differs from executed delta"
            );
        } else {
            assertGt(wethDelta, 0, "PoolManager sell WETH delta");
            assertLt(subjectDelta, 0, "PoolManager sell subject delta");
            expected.gross = uint128(wethDelta);
            expected.subjectAmount = uint256(-int256(subjectDelta));
            assertEq(
                beforeSwap.subjectBalance - IERC20(beforeSwap.subject).balanceOf(beforeSwap.subjectAccount),
                expected.subjectAmount,
                "sell payer/custody differs from executed delta"
            );
        }

        FeeTotals storage totals = feeTotals[key.toId()];
        (expected.base, expected.component) = _expectedFees(totals, expected.gross, !buy);
        uint256 fees = expected.base + expected.component;
        uint256 net = expected.gross - fees;
        if (buy) {
            assertEq(uint256(-int256(wethDelta)), net, "buy hook delta differs from independent fee");
        } else {
            assertEq(
                hook.weth().balanceOf(beforeSwap.wethAccount) - beforeSwap.wethBalance,
                net,
                "sell hook delta differs from independent fee"
            );
        }
        assertEq(hook.totalBaseFeeLiability() - beforeSwap.baseLiability, expected.base, "base fee entitlement");
        assertEq(
            hook.manager().balanceOf(address(hook), uint160(address(hook.weth()))) - beforeSwap.claims,
            fees,
            "PoolManager minted claims differ from fees"
        );
        assertEq(
            (hook.totalRebateLiability() - beforeSwap.rebateLiability) * 1e27 + hook.totalScaledRewardLiability()
                - beforeSwap.rewardLiability,
            expected.component * 1e27,
            "component split differs from independent fee"
        );

        totals.gross += expected.gross;
        if (!buy) totals.soldGross += expected.gross;
        totals.unclaimedBase += expected.base;
    }

    function _executedDeltas(LooongHook hook, PoolKey memory key) private returns (int128 weth, int128 subject) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter != address(hook.manager()) || entry.topics.length != 3
                    || entry.topics[0] != keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
                    || entry.topics[1] != PoolId.unwrap(key.toId())
            ) continue;

            assertEq(address(uint160(uint256(entry.topics[2]))), hook.trustedRouter(), "swap consumer");
            (int128 amount0, int128 amount1,,,, uint24 lpFee) =
                abi.decode(entry.data, (int128, int128, uint160, uint128, int24, uint24));
            assertEq(lpFee, 3_000, "PoolManager LP fee");
            (weth, subject) =
                Currency.unwrap(key.currency0) == address(hook.weth()) ? (amount0, amount1) : (amount1, amount0);
            ++matches;
        }
        assertEq(matches, 1, "expected one executed PoolManager swap");
    }

    function _expectedFees(FeeTotals memory totals, uint256 gross, bool sell)
        private
        pure
        returns (uint256 base, uint256 component)
    {
        base = (totals.gross + gross) / 1_000 - totals.gross / 1_000;
        if (sell) component = (totals.soldGross + gross) * 29 / 1_000 - totals.soldGross * 29 / 1_000;
    }

    // Fixed-point iteration starts at net; each step adds independently calculated entitlements.
    // This differs from production's estimated gross plus bounded linear search.
    function _expectedGross(PoolId pool, uint256 net, bool sell) internal view returns (uint256 gross) {
        gross = net;
        for (uint256 i; i < 64; ++i) {
            (uint256 base, uint256 component) = _expectedFees(feeTotals[pool], gross, sell);
            uint256 next = net + base + component;
            if (next == gross) return gross;
            gross = next;
        }
        revert("independent gross oracle did not converge");
    }

    function _assertFeeRemainders(LooongHook hook, PoolId pool, uint256 net) internal view {
        assertEq(hook.quoteExactOutputGross(pool, net, false), _expectedGross(pool, net, false), "base remainder");
        assertEq(hook.quoteExactOutputGross(pool, net, true), _expectedGross(pool, net, true), "sell remainder");
    }
}
