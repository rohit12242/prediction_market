// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPredictionMarket} from "./interfaces/IPredictionMarket.sol";

/// @title MarketFactory
/// @notice Factory and registry for prediction markets. Handles metadata storage,
///         creation fees, and resolution time bounds validation.
contract MarketFactory is Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ─── Types ────────────────────────────────────────────────────────────────

    struct MarketMetadata {
        string question;
        string description;
        string category; // e.g. "crypto", "politics", "sports"
        string imageIpfsHash; // IPFS CID for market image
        string dataIpfsHash; // IPFS CID for full market JSON metadata
        uint256 resolutionTime;
        address creator;
        uint256 initialLiquidity;
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event MarketDeployed(
        bytes32 indexed conditionId,
        address indexed creator,
        string question,
        string dataIpfsHash,
        uint256 resolutionTime
    );

    event CreationFeeUpdated(uint256 oldFee, uint256 newFee);

    event ResolutionBoundsUpdated(uint256 minTime, uint256 maxTime);

    event FeesWithdrawn(address indexed to, uint256 amount);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InvalidResolutionTime();
    error ResolutionTimeTooSoon();
    error ResolutionTimeTooFar();
    error InsufficientCreationFee();
    error InsufficientInitialLiquidity();
    error ZeroAddress();
    error EmptyQuestion();

    // ─── State ────────────────────────────────────────────────────────────────

    IPredictionMarket public immutable predictionMarket;
    IERC20 public immutable usdc;

    bytes32[] public allConditionIds;
    mapping(bytes32 => MarketMetadata) public marketMetadata;
    mapping(address => bytes32[]) public creatorMarkets;

    uint256 public creationFee; // USDC fee to create (6 decimals), default 10 USDC
    uint256 public minResolutionTime; // e.g. 1 hours
    uint256 public maxResolutionTime; // e.g. 365 days

    uint256 public accruedFees; // accumulated creation fees

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _predictionMarket PredictionMarket contract address
    /// @param _usdc USDC token address
    /// @param _owner Factory owner
    constructor(address _predictionMarket, address _usdc, address _owner) Ownable(_owner) {
        if (_predictionMarket == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();

        predictionMarket = IPredictionMarket(_predictionMarket);
        usdc = IERC20(_usdc);
        creationFee = 10e6; // 10 USDC
        minResolutionTime = 1 hours;
        maxResolutionTime = 365 days;
    }

    // ─── Market Creation ──────────────────────────────────────────────────────

    /// @notice Create a new prediction market with metadata.
    ///         Caller must approve: creationFee + metadata.initialLiquidity USDC.
    /// @param questionId Unique question identifier (e.g. keccak256 of question + nonce)
    /// @param metadata Market metadata struct
    /// @param initialLiquidity Initial USDC liquidity to bootstrap (must >= INITIAL_LIQUIDITY_REQUIRED)
    /// @return conditionId The market condition ID
    function createMarket(bytes32 questionId, MarketMetadata calldata metadata, uint256 initialLiquidity)
        external
        whenNotPaused
        returns (bytes32 conditionId)
    {
        // Validate inputs
        if (bytes(metadata.question).length == 0) revert EmptyQuestion();
        if (metadata.resolutionTime <= block.timestamp) revert InvalidResolutionTime();

        uint256 timeDelta = metadata.resolutionTime - block.timestamp;
        if (timeDelta < minResolutionTime) revert ResolutionTimeTooSoon();
        if (timeDelta > maxResolutionTime) revert ResolutionTimeTooFar();

        uint256 totalRequired = creationFee + initialLiquidity;
        usdc.safeTransferFrom(msg.sender, address(this), totalRequired);

        // Accrue creation fee
        accruedFees += creationFee;

        // Approve PredictionMarket to use initialLiquidity
        usdc.safeIncreaseAllowance(address(predictionMarket), initialLiquidity);

        // Create market (transfers initialLiquidity from this contract)
        conditionId = predictionMarket.createMarket(
            questionId, metadata.question, metadata.dataIpfsHash, metadata.resolutionTime, initialLiquidity
        );

        // Store metadata
        marketMetadata[conditionId] = MarketMetadata({
            question: metadata.question,
            description: metadata.description,
            category: metadata.category,
            imageIpfsHash: metadata.imageIpfsHash,
            dataIpfsHash: metadata.dataIpfsHash,
            resolutionTime: metadata.resolutionTime,
            creator: msg.sender,
            initialLiquidity: initialLiquidity
        });

        allConditionIds.push(conditionId);
        creatorMarkets[msg.sender].push(conditionId);

        emit MarketDeployed(conditionId, msg.sender, metadata.question, metadata.dataIpfsHash, metadata.resolutionTime);
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /// @notice Total number of markets created through this factory
    function getMarketCount() external view returns (uint256) {
        return allConditionIds.length;
    }

    /// @notice Get all market condition IDs
    function getAllMarkets() external view returns (bytes32[] memory) {
        return allConditionIds;
    }

    /// @notice Get all markets created by a specific creator
    function getMarketsByCreator(address creator) external view returns (bytes32[] memory) {
        return creatorMarkets[creator];
    }

    /// @notice Get full metadata for a market
    function getMarketMetadata(bytes32 conditionId) external view returns (MarketMetadata memory) {
        return marketMetadata[conditionId];
    }

    /// @notice Get paginated list of markets
    /// @param offset Starting index
    /// @param limit Maximum number to return
    function getMarketsPaginated(uint256 offset, uint256 limit) external view returns (bytes32[] memory result) {
        uint256 total = allConditionIds.length;
        if (offset >= total) return new bytes32[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        result = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = allConditionIds[i];
        }
    }

    // ─── Admin Functions ──────────────────────────────────────────────────────

    /// @notice Update creation fee
    function setCreationFee(uint256 newFee) external onlyOwner {
        emit CreationFeeUpdated(creationFee, newFee);
        creationFee = newFee;
    }

    /// @notice Update resolution time bounds
    function setResolutionTimeBounds(uint256 minTime, uint256 maxTime) external onlyOwner {
        require(minTime < maxTime, "Factory: invalid bounds");
        require(maxTime <= 10 * 365 days, "Factory: max too large");
        minResolutionTime = minTime;
        maxResolutionTime = maxTime;
        emit ResolutionBoundsUpdated(minTime, maxTime);
    }

    /// @notice Withdraw accumulated creation fees
    /// @param to Recipient address
    function withdrawFees(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = accruedFees;
        accruedFees = 0;
        usdc.safeTransfer(to, amount);
        emit FeesWithdrawn(to, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
