// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IConditionalTokens} from "./IConditionalTokens.sol";

/// @title IFPMM
/// @notice Interface for the Fixed Product Market Maker
interface IFPMM {
    // ─── Events ───────────────────────────────────────────────────────────────

    event FPMMFundingAdded(address indexed funder, uint256[] amountsAdded, uint256 sharesMinted);

    event FPMMFundingRemoved(address indexed funder, uint256[] amountsRemoved, uint256 collateralRemovedFromFeePool, uint256 sharesBurnt);

    event FPMMBuy(
        address indexed buyer,
        uint256 investmentAmount,
        uint256 feeAmount,
        uint256 indexed outcomeIndex,
        uint256 outcomeTokensBought
    );

    event FPMMSell(
        address indexed seller,
        uint256 returnAmount,
        uint256 feeAmount,
        uint256 indexed outcomeIndex,
        uint256 outcomeTokensSold
    );

    // ─── Functions ────────────────────────────────────────────────────────────

    function addFunding(uint256 addedFunds, uint256[] calldata distributionHint)
        external
        returns (uint256 mintedShares, uint256[] memory sendBackAmounts);

    function removeFunding(uint256 sharesToBurn) external returns (uint256[] memory sendAmounts);

    function buy(uint256 investmentAmount, uint256 outcomeIndex, uint256 minOutcomeTokensToBuy)
        external
        returns (uint256 outcomeTokensBought);

    function sell(uint256 returnAmount, uint256 outcomeIndex, uint256 maxOutcomeTokensToSell)
        external
        returns (uint256 outcomeTokensSold);

    function calcBuyAmount(uint256 investmentAmount, uint256 outcomeIndex) external view returns (uint256);

    function calcSellAmount(uint256 returnAmount, uint256 outcomeIndex) external view returns (uint256);

    function collateralToken() external view returns (IERC20);

    function conditionalTokens() external view returns (IConditionalTokens);

    function conditionId() external view returns (bytes32);

    function fee() external view returns (uint256);
}

/// @title IFPMMFactory
/// @notice Interface for FPMM factory
interface IFPMMFactory {
    event FPMMCreated(
        address indexed creator,
        address indexed fpmm,
        address indexed collateralToken,
        bytes32 conditionId,
        uint256 fee
    );

    function createFPMM(
        IERC20 collateralToken,
        IConditionalTokens conditionalTokens,
        bytes32 conditionId,
        uint256 fee
    ) external returns (address fpmm);
}
