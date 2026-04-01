// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MarketMath
/// @notice Pure math helpers for FPMM calculations and price computation
library MarketMath {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // ─── FPMM Math ────────────────────────────────────────────────────────────

    /// @notice Calculate outcome tokens received when buying with FPMM
    /// @dev For binary market:
    ///      After splitting investmentAmount, all reserves increase by investmentAmount.
    ///      Then we solve for outcomeTokensBought that restores the product invariant.
    ///      Formula: outcomeTokensBought = r_i + netInvestment - k / product(r_j + netInvestment for j != i)
    /// @param reserves Current reserves array (length = outcomeSlotCount)
    /// @param investmentAmount Net collateral amount after fee
    /// @param outcomeIndex Index of outcome to buy
    /// @return outcomeTokensBought Number of outcome tokens received
    function calcBuyAmount(uint256[] memory reserves, uint256 investmentAmount, uint256 outcomeIndex)
        internal
        pure
        returns (uint256 outcomeTokensBought)
    {
        require(reserves.length >= 2, "MarketMath: invalid reserves");
        require(outcomeIndex < reserves.length, "MarketMath: invalid outcome index");

        // Compute product of all other reserves after adding investmentAmount
        uint256 otherReservesProduct = 1;
        for (uint256 i = 0; i < reserves.length; i++) {
            if (i != outcomeIndex) {
                otherReservesProduct = otherReservesProduct * (reserves[i] + investmentAmount);
            }
        }

        // Current product invariant
        uint256 k = _product(reserves);

        // r_i + investmentAmount - k / otherReservesProduct
        uint256 newReserveI = reserves[outcomeIndex] + investmentAmount;
        uint256 kDivOther = k / otherReservesProduct;

        if (newReserveI <= kDivOther) return 0;
        outcomeTokensBought = newReserveI - kDivOther;
    }

    /// @notice Calculate outcome tokens required to sell to receive returnAmount collateral
    /// @dev Inverse of buy: given returnAmount collateral out, find how many outcome tokens in.
    ///      After merging, all reserves decrease by returnAmount.
    ///      outcomeTokensToSell = k / product(r_j - returnAmount for j != i) - (r_i - returnAmount)
    /// @param reserves Current reserves array
    /// @param returnAmount Net collateral to return after fee
    /// @param outcomeIndex Index of outcome to sell
    /// @return outcomeTokensToSell Number of outcome tokens needed
    function calcSellAmount(uint256[] memory reserves, uint256 returnAmount, uint256 outcomeIndex)
        internal
        pure
        returns (uint256 outcomeTokensToSell)
    {
        require(reserves.length >= 2, "MarketMath: invalid reserves");
        require(outcomeIndex < reserves.length, "MarketMath: invalid outcome index");

        // Product of other reserves after subtracting returnAmount
        uint256 otherReservesProduct = 1;
        for (uint256 i = 0; i < reserves.length; i++) {
            if (i != outcomeIndex) {
                require(reserves[i] > returnAmount, "MarketMath: insufficient liquidity");
                otherReservesProduct = otherReservesProduct * (reserves[i] - returnAmount);
            }
        }

        uint256 k = _product(reserves);
        uint256 kDivOther = (k + otherReservesProduct - 1) / otherReservesProduct; // ceiling division

        uint256 newReserveI = reserves[outcomeIndex] - returnAmount;
        if (kDivOther <= newReserveI) return 0;
        outcomeTokensToSell = kDivOther - newReserveI;
    }

    /// @notice Apply fee deduction: netAmount = amount * (BPS_DENOMINATOR - feeBps) / BPS_DENOMINATOR
    function applyFee(uint256 amount, uint256 feeBps) internal pure returns (uint256 netAmount, uint256 feeAmount) {
        feeAmount = (amount * feeBps) / BPS_DENOMINATOR;
        netAmount = amount - feeAmount;
    }

    /// @notice Compute the square root using the Babylonian method (Newton's method)
    /// @param x Input value
    /// @return y Floor sqrt of x
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        if (x <= 3) return 1;

        uint256 z = x;
        y = x;
        z = z / 2 + 1;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @notice Compute sqrt * 2^96 for Q64.96 fixed-point price
    /// @param x Input value (typically ratio of two token amounts * 1e18)
    /// @return sqrtPriceX96 The sqrt price in Q64.96 format
    function sqrtX96(uint256 x) internal pure returns (uint256 sqrtPriceX96) {
        uint256 s = sqrt(x);
        // Multiply by 2^96 / 1e9 (since sqrt(1e18) = 1e9)
        sqrtPriceX96 = s * (2 ** 96) / 1e9;
    }

    /// @notice Compute geometric mean of an array (for LP share calculation)
    function geometricMean(uint256[] memory values) internal pure returns (uint256) {
        uint256 n = values.length;
        if (n == 0) return 0;
        if (n == 1) return values[0];

        // For n=2: geometric mean = sqrt(a * b)
        if (n == 2) {
            return sqrt(values[0] * values[1]);
        }

        // General case: iteratively compute
        uint256 result = values[0];
        for (uint256 i = 1; i < n; i++) {
            result = sqrt(result * values[i]);
        }
        return result;
    }

    /// @notice Compute product of all elements in an array
    function _product(uint256[] memory values) internal pure returns (uint256 result) {
        result = 1;
        for (uint256 i = 0; i < values.length; i++) {
            result = result * values[i];
        }
    }

    /// @notice Minimum of two values
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @notice Maximum of two values
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
