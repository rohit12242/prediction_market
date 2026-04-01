// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ConditionalTokens
/// @notice Gnosis-style conditional token framework for binary prediction markets.
///         Conditions are identified by keccak256(oracle, questionId, outcomeSlotCount).
///         Positions are ERC-1155 tokens: positionId = keccak256(collateralToken, collectionId).
contract ConditionalTokens is ERC1155 {
    using SafeERC20 for IERC20;

    // ─── Events ───────────────────────────────────────────────────────────────

    event ConditionPrepared(
        bytes32 indexed conditionId,
        address indexed oracle,
        bytes32 indexed questionId,
        uint256 outcomeSlotCount
    );

    event PositionSplit(
        address indexed stakeholder,
        IERC20 collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 indexed conditionId,
        uint256[] partition,
        uint256 amount
    );

    event PositionsMerge(
        address indexed stakeholder,
        IERC20 collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 indexed conditionId,
        uint256[] partition,
        uint256 amount
    );

    event PayoutRedemption(
        address indexed redeemer,
        IERC20 indexed collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 conditionId,
        uint256[] indexSets,
        uint256 payout
    );

    event ConditionResolution(
        bytes32 indexed conditionId,
        address indexed oracle,
        bytes32 indexed questionId,
        uint256 outcomeSlotCount,
        uint256[] payoutNumerators
    );

    // ─── Errors ───────────────────────────────────────────────────────────────

    error ConditionAlreadyPrepared();
    error ConditionNotPrepared();
    error ConditionAlreadyResolved();
    error ConditionNotResolved();
    error InvalidPartition();
    error InvalidOutcomeSlotCount();
    error InvalidPayoutsLength();
    error UnauthorizedOracle();
    error EmptyPartition();
    error InsufficientBalance();
    error ZeroAmount();
    error InvalidIndexSet();
    error PayoutZero();

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice Maps conditionId => outcomeIndex => payout numerator
    mapping(bytes32 => mapping(uint256 => uint256)) public payoutNumerators;

    /// @notice Maps conditionId => payout denominator (sum of numerators; 0 = unresolved)
    mapping(bytes32 => uint256) public payoutDenominator;

    /// @notice Maps conditionId => number of outcome slots
    mapping(bytes32 => uint256) internal outcomeSlotCounts;

    /// @notice Maps conditionId => oracle address
    mapping(bytes32 => address) internal conditionOracles;

    /// @notice Maps conditionId => questionId
    mapping(bytes32 => bytes32) internal conditionQuestionIds;

    /// @notice ERC-1155 token total supplies per positionId (uint256 tokenId)
    mapping(uint256 => uint256) public totalSupply;

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor() ERC1155("") {}

    // ─── Condition Management ─────────────────────────────────────────────────

    /// @notice Register a new condition. Must be called before splitting positions.
    /// @param oracle Address that will report payouts for this condition
    /// @param questionId Identifier for the question (e.g. keccak256 of question string)
    /// @param outcomeSlotCount Number of possible outcomes (2 for binary)
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external {
        if (outcomeSlotCount < 2) revert InvalidOutcomeSlotCount();
        if (outcomeSlotCount > 256) revert InvalidOutcomeSlotCount();

        bytes32 conditionId = getConditionId(oracle, questionId, outcomeSlotCount);

        if (outcomeSlotCounts[conditionId] != 0) revert ConditionAlreadyPrepared();

        outcomeSlotCounts[conditionId] = outcomeSlotCount;
        conditionOracles[conditionId] = oracle;
        conditionQuestionIds[conditionId] = questionId;

        emit ConditionPrepared(conditionId, oracle, questionId, outcomeSlotCount);
    }

    /// @notice Report payouts for a condition. Only callable by the registered oracle.
    /// @param questionId The question identifier
    /// @param payouts Array of payout numerators (length must match outcomeSlotCount)
    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external {
        // Find the condition by iterating from msg.sender as oracle
        // The oracle calls this with questionId; we reconstruct conditionId
        uint256 outcomeSlotCount = payouts.length;
        bytes32 conditionId = getConditionId(msg.sender, questionId, outcomeSlotCount);

        if (outcomeSlotCounts[conditionId] == 0) revert ConditionNotPrepared();
        if (payoutDenominator[conditionId] != 0) revert ConditionAlreadyResolved();
        if (payouts.length != outcomeSlotCount) revert InvalidPayoutsLength();

        uint256 denominator = 0;
        for (uint256 i = 0; i < payouts.length; i++) {
            denominator += payouts[i];
            payoutNumerators[conditionId][i] = payouts[i];
        }

        if (denominator == 0) revert PayoutZero();
        payoutDenominator[conditionId] = denominator;

        emit ConditionResolution(conditionId, msg.sender, questionId, outcomeSlotCount, payouts);
    }

    // ─── Position Splitting ───────────────────────────────────────────────────

    /// @notice Split a collateral position into conditional positions.
    ///         For binary markets: partition=[1,2] splits into YES (indexSet=1) and NO (indexSet=2) tokens.
    /// @param collateralToken The ERC-20 collateral token
    /// @param parentCollectionId The parent collection ID (bytes32(0) for root)
    /// @param conditionId The condition to split on
    /// @param partition Array of index sets (each is a bitmask of outcome indices)
    /// @param amount Amount of collateral (or parent tokens) to split
    function splitPosition(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external {
        if (amount == 0) revert ZeroAmount();
        if (partition.length < 2) revert EmptyPartition();
        if (outcomeSlotCounts[conditionId] == 0) revert ConditionNotPrepared();

        uint256 outcomeSlotCount = outcomeSlotCounts[conditionId];

        // Validate partition: all index sets must be non-overlapping and non-empty
        _validatePartition(partition, outcomeSlotCount);

        if (parentCollectionId == bytes32(0)) {
            // Root split: transfer collateral from caller
            collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        } else {
            // Nested split: burn parent position tokens
            uint256 parentPositionId = uint256(getPositionId(collateralToken, parentCollectionId));
            _burn(msg.sender, parentPositionId, amount);
            totalSupply[parentPositionId] -= amount;
        }

        // Mint outcome tokens for each partition element
        for (uint256 i = 0; i < partition.length; i++) {
            bytes32 collectionId = getCollectionId(parentCollectionId, conditionId, partition[i]);
            uint256 positionId = uint256(getPositionId(collateralToken, collectionId));
            _mint(msg.sender, positionId, amount, "");
            totalSupply[positionId] += amount;
        }

        emit PositionSplit(msg.sender, collateralToken, parentCollectionId, conditionId, partition, amount);
    }

    /// @notice Merge conditional positions back into collateral (or parent positions).
    ///         The caller must hold equal amounts of all partition positions.
    /// @param collateralToken The ERC-20 collateral token
    /// @param parentCollectionId The parent collection ID (bytes32(0) for root)
    /// @param conditionId The condition
    /// @param partition Array of index sets to merge
    /// @param amount Amount of each position to merge
    function mergePositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external {
        if (amount == 0) revert ZeroAmount();
        if (partition.length < 2) revert EmptyPartition();
        if (outcomeSlotCounts[conditionId] == 0) revert ConditionNotPrepared();

        uint256 outcomeSlotCount = outcomeSlotCounts[conditionId];
        _validatePartition(partition, outcomeSlotCount);

        // Burn outcome tokens for each partition element
        for (uint256 i = 0; i < partition.length; i++) {
            bytes32 collectionId = getCollectionId(parentCollectionId, conditionId, partition[i]);
            uint256 positionId = uint256(getPositionId(collateralToken, collectionId));
            _burn(msg.sender, positionId, amount);
            totalSupply[positionId] -= amount;
        }

        if (parentCollectionId == bytes32(0)) {
            // Root merge: return collateral to caller
            collateralToken.safeTransfer(msg.sender, amount);
        } else {
            // Nested merge: mint parent position tokens
            uint256 parentPositionId = uint256(getPositionId(collateralToken, parentCollectionId));
            _mint(msg.sender, parentPositionId, amount, "");
            totalSupply[parentPositionId] += amount;
        }

        emit PositionsMerge(msg.sender, collateralToken, parentCollectionId, conditionId, partition, amount);
    }

    /// @notice Redeem winning positions after condition resolution.
    /// @param collateralToken The ERC-20 collateral token
    /// @param parentCollectionId The parent collection ID (bytes32(0) for root)
    /// @param conditionId The resolved condition
    /// @param indexSets Array of index sets to redeem
    function redeemPositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external {
        if (payoutDenominator[conditionId] == 0) revert ConditionNotResolved();
        if (indexSets.length == 0) revert EmptyPartition();

        uint256 denominator = payoutDenominator[conditionId];
        uint256 totalPayout = 0;

        for (uint256 i = 0; i < indexSets.length; i++) {
            uint256 indexSet = indexSets[i];
            if (indexSet == 0) revert InvalidIndexSet();

            bytes32 collectionId = getCollectionId(parentCollectionId, conditionId, indexSet);
            uint256 positionId = uint256(getPositionId(collateralToken, collectionId));

            uint256 balance = balanceOf(msg.sender, positionId);
            if (balance == 0) continue;

            // Compute payout numerator for this index set (sum of outcome numerators in set)
            uint256 payoutNumerator = 0;
            uint256 outcomeSlotCount = outcomeSlotCounts[conditionId];
            for (uint256 j = 0; j < outcomeSlotCount; j++) {
                if ((indexSet >> j) & 1 == 1) {
                    payoutNumerator += payoutNumerators[conditionId][j];
                }
            }

            uint256 payout = (balance * payoutNumerator) / denominator;
            totalPayout += payout;

            _burn(msg.sender, positionId, balance);
            totalSupply[positionId] -= balance;
        }

        if (totalPayout > 0) {
            if (parentCollectionId == bytes32(0)) {
                collateralToken.safeTransfer(msg.sender, totalPayout);
            } else {
                uint256 parentPositionId = uint256(getPositionId(collateralToken, parentCollectionId));
                _mint(msg.sender, parentPositionId, totalPayout, "");
                totalSupply[parentPositionId] += totalPayout;
            }
        }

        emit PayoutRedemption(msg.sender, collateralToken, parentCollectionId, conditionId, indexSets, totalPayout);
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /// @notice Compute condition ID from oracle, questionId, and outcome slot count
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(oracle, questionId, outcomeSlotCount));
    }

    /// @notice Compute collection ID from parent collection, condition, and index set
    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(parentCollectionId, conditionId, indexSet));
    }

    /// @notice Compute position ID from collateral token and collection ID
    function getPositionId(IERC20 collateralToken, bytes32 collectionId) public pure returns (bytes32) {
        return keccak256(abi.encode(collateralToken, collectionId));
    }

    /// @notice Get the number of outcome slots for a condition
    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256) {
        return outcomeSlotCounts[conditionId];
    }

    /// @notice Check if a condition is prepared
    function isConditionPrepared(bytes32 conditionId) external view returns (bool) {
        return outcomeSlotCounts[conditionId] != 0;
    }

    /// @notice Check if a condition is resolved
    function isConditionResolved(bytes32 conditionId) external view returns (bool) {
        return payoutDenominator[conditionId] != 0;
    }

    // ─── Internal Helpers ─────────────────────────────────────────────────────

    /// @dev Validate that partition is non-overlapping and covers valid outcomes
    function _validatePartition(uint256[] memory partition, uint256 outcomeSlotCount) internal pure {
        uint256 fullIndexSet = (1 << outcomeSlotCount) - 1;
        uint256 unionIndexSet = 0;

        for (uint256 i = 0; i < partition.length; i++) {
            uint256 indexSet = partition[i];
            if (indexSet == 0) revert InvalidIndexSet();
            if (indexSet > fullIndexSet) revert InvalidIndexSet();
            if (unionIndexSet & indexSet != 0) revert InvalidPartition(); // overlapping
            unionIndexSet |= indexSet;
        }
    }
}
