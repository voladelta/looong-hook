// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library LooongAccounting {
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;
    uint256 internal constant BASE_FEE_RATE = 1_000;
    uint256 internal constant SELL_COMPONENT_RATE = 29_000;
    uint256 internal constant MATURITY = 30 days;
    uint256 internal constant PROFIT_SHARE_RATE = 3_000;
    uint256 internal constant PROFIT_SHARE_DENOMINATOR = 10_000 * MATURITY;

    error NoExactGrossAmount(uint256 netAmount);

    function previewFee(uint256 gross, uint256 rate, uint256 remainder)
        internal
        pure
        returns (uint256 fee, uint256 nextRemainder)
    {
        uint256 numerator = gross * rate + remainder;
        fee = numerator / FEE_DENOMINATOR;
        nextRemainder = numerator % FEE_DENOMINATOR;
    }

    function previewFees(uint256 gross, bool sell, uint256 baseRemainder, uint256 componentRemainder)
        internal
        pure
        returns (uint256 baseFee, uint256 componentFee)
    {
        (baseFee,) = previewFee(gross, BASE_FEE_RATE, baseRemainder);
        if (sell) (componentFee,) = previewFee(gross, SELL_COMPONENT_RATE, componentRemainder);
    }

    function solveGross(uint256 net, bool sell, uint256 baseRemainder, uint256 componentRemainder)
        internal
        pure
        returns (uint256 gross)
    {
        uint256 totalRate = BASE_FEE_RATE + (sell ? SELL_COMPONENT_RATE : 0);
        uint256 estimate = Math.mulDiv(net, FEE_DENOMINATOR, FEE_DENOMINATOR - totalRate, Math.Rounding.Ceil);
        gross = estimate > 2 ? estimate - 2 : net;

        for (uint256 i; i < 17; ++i) {
            (uint256 baseFee, uint256 componentFee) = previewFees(gross, sell, baseRemainder, componentRemainder);
            if (gross - baseFee - componentFee == net) return gross;
            ++gross;
        }
        revert NoExactGrossAmount(net);
    }

    function allocateBasis(uint256 remainingBasis, uint256 remainingTokens, uint256 tokenAmount)
        internal
        pure
        returns (uint256)
    {
        if (tokenAmount == remainingTokens) return remainingBasis;
        return Math.mulDiv(remainingBasis, tokenAmount, remainingTokens);
    }

    function earlyProfitShare(
        uint256 eligibleProfit,
        uint256 timeRemaining,
        uint256 carriedRemainder,
        uint256 componentFee
    ) internal pure returns (uint256 share, uint256 nextRemainder) {
        uint256 numerator =
            eligibleProfit * PROFIT_SHARE_RATE * timeRemaining + carriedRemainder;
        share = numerator / PROFIT_SHARE_DENOMINATOR;
        nextRemainder = numerator % PROFIT_SHARE_DENOMINATOR;
        if (share > componentFee) share = componentFee;
    }
}
