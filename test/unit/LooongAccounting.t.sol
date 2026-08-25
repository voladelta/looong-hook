// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {LooongAccounting} from "../../src/libraries/LooongAccounting.sol";

contract LooongAccountingHarness {
    function fee(uint256 gross, uint256 rate, uint256 remainder) external pure returns (uint256, uint256) {
        return LooongAccounting.previewFee(gross, rate, remainder);
    }

    function solve(uint256 net, bool sell, uint256 baseRemainder, uint256 componentRemainder)
        external
        pure
        returns (uint256)
    {
        return LooongAccounting.solveGross(net, sell, baseRemainder, componentRemainder);
    }

    function fees(uint256 gross, bool sell, uint256 baseRemainder, uint256 componentRemainder)
        external
        pure
        returns (uint256, uint256)
    {
        return LooongAccounting.previewFees(gross, sell, baseRemainder, componentRemainder);
    }

    function basis(uint256 remainingBasis, uint256 remainingTokens, uint256 tokenAmount)
        external
        pure
        returns (uint256)
    {
        return LooongAccounting.allocateBasis(remainingBasis, remainingTokens, tokenAmount);
    }

    function early(uint256 profit, uint256 remaining, uint256 carried, uint256 cap)
        external
        pure
        returns (uint256, uint256)
    {
        return LooongAccounting.earlyProfitShare(profit, remaining, carried, cap);
    }
}

contract LooongAccountingTest is Test {
    LooongAccountingHarness private harness = new LooongAccountingHarness();

    function test_frozenFeeRatesAndIndependentRemainders() public view {
        (uint256 baseFee, uint256 baseRemainder) = harness.fee(1_000_000, 1_000, 0);
        (uint256 componentFee, uint256 componentRemainder) = harness.fee(1_000_000, 29_000, 0);
        assertEq(baseFee, 1_000);
        assertEq(componentFee, 29_000);
        assertEq(baseRemainder, 0);
        assertEq(componentRemainder, 0);
    }

    function test_splitVolumeCannotSuppressFees() public view {
        uint256 baseFees;
        uint256 componentFees;
        uint256 baseRemainder;
        uint256 componentRemainder;
        for (uint256 i; i < 1_000; ++i) {
            uint256 fee;
            (fee, baseRemainder) = harness.fee(1_000, 1_000, baseRemainder);
            baseFees += fee;
            (fee, componentRemainder) = harness.fee(1_000, 29_000, componentRemainder);
            componentFees += fee;
        }
        assertEq(baseFees, 1_000);
        assertEq(componentFees, 29_000);
        assertEq(baseRemainder, 0);
        assertEq(componentRemainder, 0);
    }

    function testFuzz_solverFindsExactIntegerGross(
        uint128 rawNet,
        bool sell,
        uint32 rawBaseRemainder,
        uint32 rawComponentRemainder
    ) public view {
        uint256 net = bound(rawNet, 1_000, uint128(type(int128).max) / 2);
        uint256 baseRemainder = bound(rawBaseRemainder, 0, 999_999);
        uint256 componentRemainder = bound(rawComponentRemainder, 0, 999_999);
        uint256 gross = harness.solve(net, sell, baseRemainder, componentRemainder);
        (uint256 baseFee, uint256 componentFee) = harness.fees(gross, sell, baseRemainder, componentRemainder);
        assertEq(gross - baseFee - componentFee, net);
    }

    function test_basisFullCloseConsumesTheExactRemainder() public view {
        assertEq(harness.basis(11, 3, 1), 3);
        assertEq(harness.basis(8, 2, 2), 8);
    }

    function test_earlyProfitShareDecaysAndIsCapped() public view {
        (uint256 openingShare,) = harness.early(100 ether, 30 days, 0, type(uint256).max);
        (uint256 halfShare,) = harness.early(100 ether, 15 days, 0, type(uint256).max);
        (uint256 matureShare,) = harness.early(100 ether, 0, 0, type(uint256).max);
        (uint256 cappedShare,) = harness.early(100 ether, 30 days, 0, 1 ether);
        assertEq(openingShare, 30 ether);
        assertEq(halfShare, 15 ether);
        assertEq(matureShare, 0);
        assertEq(cappedShare, 1 ether);
    }
}
