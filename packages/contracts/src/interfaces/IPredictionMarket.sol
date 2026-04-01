// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPredictionMarket
/// @notice Interface for the core PredictionMarket contract
interface IPredictionMarket {
    // ─── Types ────────────────────────────────────────────────────────────────

    enum MarketStatus {
        Active,
        PendingResolution,
        Resolved,
        Cancelled
    }

    struct MarketInfo {
        bytes32 conditionId;
        address fpmm;
        address clob;
        string question;
        string ipfsHash;
        uint256 createdAt;
        uint256 resolutionTime;
        MarketStatus status;
        address creator;
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event MarketCreated(
        bytes32 indexed conditionId,
        address indexed creator,
        string question,
        string ipfsHash,
        uint256 resolutionTime
    );

    event LiquidityAdded(bytes32 indexed conditionId, address indexed provider, uint256 amount, uint256 lpShares);

    event LiquidityRemoved(
        bytes32 indexed conditionId, address indexed provider, uint256 lpShares, uint256[] amounts
    );

    event OutcomeBought(
        bytes32 indexed conditionId,
        address indexed buyer,
        uint256 outcomeIndex,
        uint256 usdcAmount,
        uint256 tokensBought
    );

    event OutcomeSold(
        bytes32 indexed conditionId,
        address indexed seller,
        uint256 outcomeIndex,
        uint256 returnAmount,
        uint256 tokensSold
    );

    event MarketResolved(bytes32 indexed conditionId, uint256[] payouts);

    event MarketCancelled(bytes32 indexed conditionId);

    event PositionsRedeemed(bytes32 indexed conditionId, address indexed redeemer, uint256 payout);

    // ─── Functions ────────────────────────────────────────────────────────────

    function createMarket(
        bytes32 questionId,
        string calldata question,
        string calldata ipfsHash,
        uint256 resolutionTime,
        uint256 initialLiquidity
    ) external returns (bytes32 conditionId);

    function addLiquidity(bytes32 conditionId, uint256 amount) external;

    function removeLiquidity(bytes32 conditionId, uint256 lpShares) external;

    function buyOutcome(bytes32 conditionId, uint256 outcomeIndex, uint256 usdcAmount, uint256 minTokens)
        external
        returns (uint256);

    function sellOutcome(bytes32 conditionId, uint256 outcomeIndex, uint256 returnAmount, uint256 maxTokens)
        external
        returns (uint256);

    function initiateResolution(bytes32 conditionId) external;

    function resolveMarket(bytes32 conditionId, uint256[] calldata payouts) external;

    function cancelMarket(bytes32 conditionId) external;

    function redeemPositions(bytes32 conditionId) external;

    function getMarket(bytes32 conditionId) external view returns (MarketInfo memory);
}
