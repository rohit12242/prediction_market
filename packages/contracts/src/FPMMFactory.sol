// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";
import {IFPMMFactory} from "./interfaces/IFPMM.sol";
import {MarketMath} from "./lib/MarketMath.sol";

/// @title FixedProductMarketMaker
/// @notice AMM for a binary prediction market using constant product invariant.
///         LP shares are ERC-20 tokens. Fee taken on buys and sells.
///
///         FPMM buy logic (Gnosis CTF-style):
///         1. collateral is split into equal outcome tokens → all reserves increase by netInvestment
///         2. To maintain product invariant, outcomeTokensBought are removed from target reserve
///         3. outcomeTokensBought = r_i + netInv - k / (r_j + netInv) for binary
///
///         FPMM sell logic (inverse):
///         1. outcomeTokensSold returned, and returnAmount of collateral taken
///         2. All reserves decrease by returnAmount, then outcome tokens added to target reserve
///         3. outcomeTokensToSell = k / (r_j - netReturn) - (r_i - netReturn) for binary
contract FixedProductMarketMaker is ERC20, ReentrancyGuard, IERC1155Receiver {
    using SafeERC20 for IERC20;
    using MarketMath for uint256[];

    // ─── Events ───────────────────────────────────────────────────────────────

    event FPMMFundingAdded(address indexed funder, uint256[] amountsAdded, uint256 sharesMinted);

    event FPMMFundingRemoved(
        address indexed funder,
        uint256[] amountsRemoved,
        uint256 collateralRemovedFromFeePool,
        uint256 sharesBurnt
    );

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

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InsufficientFunding();
    error InvalidOutcomeIndex();
    error SlippageExceeded();
    error InsufficientLiquidity();
    error ZeroAmount();
    error InvalidFee();

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ─── State ────────────────────────────────────────────────────────────────

    IERC20 public immutable collateralToken;
    IConditionalTokens public immutable conditionalTokens;
    bytes32 public immutable conditionId;
    uint256 public immutable outcomeCount; // 2 for binary markets
    uint256 public fee; // fee in basis points (e.g. 200 = 2%)

    /// @dev Outcome token reserves. reserves[0] = YES tokens, reserves[1] = NO tokens.
    uint256[] internal reserves;

    /// @dev Accumulated fees in collateral
    uint256 public feePool;

    /// @dev Index sets for YES and NO: [1, 2]
    uint256[] internal indexSets;

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        IERC20 _collateralToken,
        IConditionalTokens _conditionalTokens,
        bytes32 _conditionId,
        uint256 _fee
    ) ERC20("FPMM LP Share", "FPMM-LP") {
        if (_fee >= BPS_DENOMINATOR) revert InvalidFee();
        collateralToken = _collateralToken;
        conditionalTokens = _conditionalTokens;
        conditionId = _conditionId;
        fee = _fee;
        outcomeCount = 2; // binary market

        // Initialize reserves and index sets for binary market
        reserves = new uint256[](2);
        indexSets = new uint256[](2);
        indexSets[0] = 1; // YES: bit 0 set
        indexSets[1] = 2; // NO: bit 1 set
    }

    // ─── Funding ──────────────────────────────────────────────────────────────

    /// @notice Add liquidity to the FPMM.
    /// @param addedFunds Amount of collateral to add
    /// @param distributionHint Proportional hint for initial funding distribution.
    ///        Pass empty array for equal distribution. Length must be outcomeCount or 0.
    /// @return mintedShares LP shares minted to caller
    /// @return sendBackAmounts Excess outcome tokens returned to caller (for non-uniform initial funding)
    function addFunding(uint256 addedFunds, uint256[] calldata distributionHint)
        external
        nonReentrant
        returns (uint256 mintedShares, uint256[] memory sendBackAmounts)
    {
        if (addedFunds == 0) revert ZeroAmount();

        collateralToken.safeTransferFrom(msg.sender, address(this), addedFunds);

        sendBackAmounts = new uint256[](outcomeCount);
        uint256[] memory addedAmounts = new uint256[](outcomeCount);

        uint256 totalShares = totalSupply();

        if (totalShares == 0) {
            // First funding: split collateral equally into outcome tokens
            // Then apply distribution hint to set initial prices
            _approveAndSplit(addedFunds);

            if (distributionHint.length == outcomeCount) {
                // Validate hint
                uint256 hintProduct = 1;
                for (uint256 i = 0; i < outcomeCount; i++) {
                    require(distributionHint[i] > 0, "FPMM: zero hint");
                    hintProduct = hintProduct * distributionHint[i];
                }

                // Compute amounts to send back so reserves match hint ratios
                // Initial each reserve = addedFunds outcome tokens
                // We want reserves[0] * reserves[1] = k after hint adjustment
                // reserves ratio = distributionHint[1] / distributionHint[0]
                // Let r0 = addedFunds * h1 / (h0 + h1), r1 = addedFunds * h0 / (h0 + h1)
                // Actually: send back so that r_i / sum(r_j) = h_i / sum(h_j)
                // Easier: LP mints sqrt(r0*r1) shares, sends back excess tokens
                uint256 hintSum = 0;
                for (uint256 i = 0; i < outcomeCount; i++) {
                    hintSum += distributionHint[i];
                }

                uint256[] memory targetReserves = new uint256[](outcomeCount);
                for (uint256 i = 0; i < outcomeCount; i++) {
                    targetReserves[i] = (addedFunds * distributionHint[i]) / hintSum;
                }

                for (uint256 i = 0; i < outcomeCount; i++) {
                    uint256 sendBack = addedFunds - targetReserves[i];
                    sendBackAmounts[i] = sendBack;
                    addedAmounts[i] = targetReserves[i];
                    reserves[i] = targetReserves[i];
                }

                mintedShares = MarketMath.sqrt(targetReserves[0] * targetReserves[1]);
            } else {
                // Equal distribution
                for (uint256 i = 0; i < outcomeCount; i++) {
                    reserves[i] = addedFunds;
                    addedAmounts[i] = addedFunds;
                }
                mintedShares = addedFunds;
            }

            // Transfer excess tokens back
            _transferSendBackAmounts(sendBackAmounts);
        } else {
            // Subsequent funding: proportional to existing reserves
            // Mint LP shares proportional to collateral / total reserves ratio
            uint256 supplyBeforeAdd = totalShares;

            _approveAndSplit(addedFunds);

            // Calculate minimum reserve ratio across outcomes
            uint256 mintRatio = type(uint256).max;
            for (uint256 i = 0; i < outcomeCount; i++) {
                if (reserves[i] > 0) {
                    uint256 ratio = (addedFunds * 1e18) / reserves[i];
                    if (ratio < mintRatio) mintRatio = ratio;
                }
            }

            mintedShares = (supplyBeforeAdd * mintRatio) / 1e18;

            // Compute added amounts proportionally and return excess
            for (uint256 i = 0; i < outcomeCount; i++) {
                uint256 added = (reserves[i] * mintRatio) / 1e18;
                addedAmounts[i] = added;
                sendBackAmounts[i] = addedFunds - added;
                reserves[i] += added;
            }

            _transferSendBackAmounts(sendBackAmounts);
        }

        _mint(msg.sender, mintedShares);

        emit FPMMFundingAdded(msg.sender, addedAmounts, mintedShares);
    }

    /// @notice Remove liquidity from the FPMM.
    /// @param sharesToBurn Number of LP shares to burn
    /// @return sendAmounts Collateral amounts per outcome returned to caller
    function removeFunding(uint256 sharesToBurn) external nonReentrant returns (uint256[] memory sendAmounts) {
        if (sharesToBurn == 0) revert ZeroAmount();

        uint256 totalShares = totalSupply();
        require(totalShares > 0, "FPMM: no shares");

        sendAmounts = new uint256[](outcomeCount);

        // Calculate pro-rata share of each reserve
        uint256 collateralFromFeePool = (feePool * sharesToBurn) / totalShares;
        feePool -= collateralFromFeePool;

        for (uint256 i = 0; i < outcomeCount; i++) {
            sendAmounts[i] = (reserves[i] * sharesToBurn) / totalShares;
            reserves[i] -= sendAmounts[i];
        }

        _burn(msg.sender, sharesToBurn);

        // Merge outcome tokens back to collateral and transfer
        // We need to merge the minimum of the outcome tokens as full sets
        uint256 minAmount = type(uint256).max;
        for (uint256 i = 0; i < outcomeCount; i++) {
            if (sendAmounts[i] < minAmount) minAmount = sendAmounts[i];
        }

        if (minAmount > 0) {
            // Merge full outcome sets into collateral
            _approveConditionalTokens();
            conditionalTokens.mergePositions(collateralToken, bytes32(0), conditionId, indexSets, minAmount);

            // Transfer merged collateral
            collateralToken.safeTransfer(msg.sender, minAmount + collateralFromFeePool);
        } else if (collateralFromFeePool > 0) {
            collateralToken.safeTransfer(msg.sender, collateralFromFeePool);
        }

        // Transfer remaining partial outcome tokens directly
        for (uint256 i = 0; i < outcomeCount; i++) {
            uint256 remainder = sendAmounts[i] - minAmount;
            if (remainder > 0) {
                bytes32 collectionId =
                    conditionalTokens.getCollectionId(bytes32(0), conditionId, indexSets[i]);
                uint256 positionId = uint256(conditionalTokens.getPositionId(collateralToken, collectionId));
                conditionalTokens.safeTransferFrom(address(this), msg.sender, positionId, remainder, "");
            }
        }

        emit FPMMFundingRemoved(msg.sender, sendAmounts, collateralFromFeePool, sharesToBurn);
    }

    // ─── Trading ──────────────────────────────────────────────────────────────

    /// @notice Buy outcome tokens with collateral.
    /// @param investmentAmount Amount of collateral to invest (including fee)
    /// @param outcomeIndex Which outcome to buy (0=YES, 1=NO)
    /// @param minOutcomeTokensToBuy Minimum tokens to receive (slippage guard)
    /// @return outcomeTokensBought Number of outcome tokens received
    function buy(uint256 investmentAmount, uint256 outcomeIndex, uint256 minOutcomeTokensToBuy)
        external
        nonReentrant
        returns (uint256 outcomeTokensBought)
    {
        if (investmentAmount == 0) revert ZeroAmount();
        if (outcomeIndex >= outcomeCount) revert InvalidOutcomeIndex();

        collateralToken.safeTransferFrom(msg.sender, address(this), investmentAmount);

        uint256 feeAmount = (investmentAmount * fee) / BPS_DENOMINATOR;
        uint256 netInvestment = investmentAmount - feeAmount;
        feePool += feeAmount;

        outcomeTokensBought = _calcBuyAmountInternal(netInvestment, outcomeIndex);
        if (outcomeTokensBought < minOutcomeTokensToBuy) revert SlippageExceeded();
        if (outcomeTokensBought == 0) revert InsufficientLiquidity();

        // Split collateral into outcome tokens (reserves increase by netInvestment)
        _approveAndSplit(netInvestment);

        // Update reserves: add netInvestment to all, remove outcomeTokensBought from target
        for (uint256 i = 0; i < outcomeCount; i++) {
            reserves[i] += netInvestment;
        }
        reserves[outcomeIndex] -= outcomeTokensBought;

        // Transfer bought outcome tokens to buyer
        bytes32 collectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, indexSets[outcomeIndex]);
        uint256 positionId = uint256(conditionalTokens.getPositionId(collateralToken, collectionId));
        conditionalTokens.safeTransferFrom(address(this), msg.sender, positionId, outcomeTokensBought, "");

        emit FPMMBuy(msg.sender, investmentAmount, feeAmount, outcomeIndex, outcomeTokensBought);
    }

    /// @notice Sell outcome tokens for collateral.
    /// @param returnAmount Amount of collateral to receive (after fee deduction)
    /// @param outcomeIndex Which outcome tokens to sell
    /// @param maxOutcomeTokensToSell Maximum tokens to give (slippage guard)
    /// @return outcomeTokensSold Number of outcome tokens spent
    function sell(uint256 returnAmount, uint256 outcomeIndex, uint256 maxOutcomeTokensToSell)
        external
        nonReentrant
        returns (uint256 outcomeTokensSold)
    {
        if (returnAmount == 0) revert ZeroAmount();
        if (outcomeIndex >= outcomeCount) revert InvalidOutcomeIndex();

        uint256 feeAmount = (returnAmount * fee) / (BPS_DENOMINATOR - fee);
        uint256 totalReturn = returnAmount + feeAmount;
        feePool += feeAmount;

        outcomeTokensSold = _calcSellAmountInternal(returnAmount, outcomeIndex);
        if (outcomeTokensSold > maxOutcomeTokensToSell) revert SlippageExceeded();
        if (outcomeTokensSold == 0) revert InsufficientLiquidity();

        // Transfer outcome tokens from seller to this contract
        bytes32 collectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, indexSets[outcomeIndex]);
        uint256 positionId = uint256(conditionalTokens.getPositionId(collateralToken, collectionId));
        conditionalTokens.safeTransferFrom(msg.sender, address(this), positionId, outcomeTokensSold, "");

        // Update reserves: add sold tokens to target reserve, then subtract totalReturn from all
        // and merge totalReturn worth of complete sets to get collateral
        reserves[outcomeIndex] += outcomeTokensSold;
        for (uint256 i = 0; i < outcomeCount; i++) {
            reserves[i] -= totalReturn;
        }

        // Merge complete sets to collateral
        _approveConditionalTokens();
        conditionalTokens.mergePositions(collateralToken, bytes32(0), conditionId, indexSets, totalReturn);

        // Send returnAmount to seller (fee stays in pool)
        collateralToken.safeTransfer(msg.sender, returnAmount);

        emit FPMMSell(msg.sender, returnAmount, feeAmount, outcomeIndex, outcomeTokensSold);
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /// @notice Calculate outcome tokens received for a given investment (before calling buy)
    function calcBuyAmount(uint256 investmentAmount, uint256 outcomeIndex) public view returns (uint256) {
        if (outcomeIndex >= outcomeCount) revert InvalidOutcomeIndex();
        uint256 feeAmount = (investmentAmount * fee) / BPS_DENOMINATOR;
        uint256 netInvestment = investmentAmount - feeAmount;
        return _calcBuyAmountInternal(netInvestment, outcomeIndex);
    }

    /// @notice Calculate outcome tokens required to sell to receive returnAmount
    function calcSellAmount(uint256 returnAmount, uint256 outcomeIndex) public view returns (uint256) {
        if (outcomeIndex >= outcomeCount) revert InvalidOutcomeIndex();
        return _calcSellAmountInternal(returnAmount, outcomeIndex);
    }

    /// @notice Get current reserves
    function getReserves() external view returns (uint256[] memory) {
        return reserves;
    }

    /// @notice Get current spot price of an outcome (in collateral per token, scaled 1e18)
    function getSpotPrice(uint256 outcomeIndex) external view returns (uint256) {
        if (outcomeIndex >= outcomeCount) revert InvalidOutcomeIndex();
        uint256 otherProduct = 1;
        for (uint256 i = 0; i < outcomeCount; i++) {
            if (i != outcomeIndex) {
                otherProduct *= reserves[i];
            }
        }
        uint256 totalProduct = 1;
        for (uint256 i = 0; i < outcomeCount; i++) {
            totalProduct *= reserves[i];
        }
        // Price ≈ otherProduct / totalProduct (simplified for binary)
        // For binary: p_YES = r_NO / (r_YES + r_NO)
        if (outcomeCount == 2) {
            uint256 sumReserves = reserves[0] + reserves[1];
            if (sumReserves == 0) return 0;
            uint256 otherIndex = outcomeIndex == 0 ? 1 : 0;
            return (reserves[otherIndex] * 1e18) / sumReserves;
        }
        return (otherProduct * 1e18) / totalProduct;
    }

    // ─── ERC-1155 Receiver ────────────────────────────────────────────────────

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }

    // ─── Internal Helpers ─────────────────────────────────────────────────────

    function _calcBuyAmountInternal(uint256 netInvestment, uint256 outcomeIndex)
        internal
        view
        returns (uint256 outcomeTokensBought)
    {
        // Binary market: (r0 + netInv - out) * (r1 + netInv) = r0 * r1
        // => out = r_i + netInv - k / product(r_j + netInv for j != i)
        uint256 otherProduct = 1;
        for (uint256 i = 0; i < outcomeCount; i++) {
            if (i != outcomeIndex) {
                otherProduct = otherProduct * (reserves[i] + netInvestment);
            }
        }

        uint256 k = _computeProduct();
        if (k == 0) return 0;

        uint256 newReserveI = reserves[outcomeIndex] + netInvestment;
        uint256 kDivOther = k / otherProduct;

        if (newReserveI <= kDivOther) return 0;
        outcomeTokensBought = newReserveI - kDivOther;
    }

    function _calcSellAmountInternal(uint256 returnAmount, uint256 outcomeIndex)
        internal
        view
        returns (uint256 outcomeTokensToSell)
    {
        // Inverse: (r_i - returnAmount + sold) * product(r_j - returnAmount for j!=i) = k
        // => sold = k / product(r_j - returnAmount for j!=i) - (r_i - returnAmount)
        uint256 otherProduct = 1;
        for (uint256 i = 0; i < outcomeCount; i++) {
            if (i != outcomeIndex) {
                if (reserves[i] <= returnAmount) revert InsufficientLiquidity();
                otherProduct = otherProduct * (reserves[i] - returnAmount);
            }
        }

        uint256 k = _computeProduct();
        if (k == 0) return 0;

        // Ceiling division to ensure invariant is maintained
        uint256 kDivOther = (k + otherProduct - 1) / otherProduct;
        if (reserves[outcomeIndex] <= returnAmount) revert InsufficientLiquidity();
        uint256 newReserveI = reserves[outcomeIndex] - returnAmount;

        if (kDivOther <= newReserveI) return 0;
        outcomeTokensToSell = kDivOther - newReserveI;
    }

    function _computeProduct() internal view returns (uint256 product) {
        product = 1;
        for (uint256 i = 0; i < outcomeCount; i++) {
            product = product * reserves[i];
        }
    }

    /// @dev Approve conditional tokens contract and split collateral into outcome tokens
    function _approveAndSplit(uint256 amount) internal {
        collateralToken.safeIncreaseAllowance(address(conditionalTokens), amount);
        conditionalTokens.splitPosition(collateralToken, bytes32(0), conditionId, indexSets, amount);
    }

    /// @dev Approve conditional tokens for merging
    function _approveConditionalTokens() internal {
        if (!conditionalTokens.isApprovedForAll(address(this), address(conditionalTokens))) {
            conditionalTokens.setApprovalForAll(address(conditionalTokens), true);
        }
    }

    /// @dev Transfer excess outcome tokens back to caller during addFunding
    function _transferSendBackAmounts(uint256[] memory sendBackAmounts) internal {
        for (uint256 i = 0; i < outcomeCount; i++) {
            if (sendBackAmounts[i] > 0) {
                bytes32 collectionId =
                    conditionalTokens.getCollectionId(bytes32(0), conditionId, indexSets[i]);
                uint256 positionId = uint256(conditionalTokens.getPositionId(collateralToken, collectionId));
                conditionalTokens.safeTransferFrom(address(this), msg.sender, positionId, sendBackAmounts[i], "");
            }
        }
    }
}

/// @title FPMMFactory
/// @notice Deploys FixedProductMarketMaker instances for prediction markets
contract FPMMFactory is IFPMMFactory {
    // ─── State ────────────────────────────────────────────────────────────────

    address[] public allFPMMs;
    mapping(bytes32 => address) public fpmmByCondition;

    // ─── Functions ────────────────────────────────────────────────────────────

    /// @notice Deploy a new FPMM for a given condition
    /// @param collateralToken The ERC-20 collateral token
    /// @param conditionalTokensAddr The conditional tokens contract
    /// @param conditionId The condition ID for this market
    /// @param fpmmFee Fee in basis points (e.g. 200 = 2%)
    /// @return fpmm The deployed FPMM address
    function createFPMM(
        IERC20 collateralToken,
        IConditionalTokens conditionalTokensAddr,
        bytes32 conditionId,
        uint256 fpmmFee
    ) external override returns (address fpmm) {
        FixedProductMarketMaker newFPMM =
            new FixedProductMarketMaker(collateralToken, conditionalTokensAddr, conditionId, fpmmFee);

        allFPMMs.push(address(newFPMM));
        fpmmByCondition[conditionId] = address(newFPMM);

        emit FPMMCreated(msg.sender, address(newFPMM), address(collateralToken), conditionId, fpmmFee);

        return address(newFPMM);
    }

    /// @notice Get total number of FPMMs created
    function getFPMMCount() external view returns (uint256) {
        return allFPMMs.length;
    }
}
