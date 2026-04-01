// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";
import {IFPMMFactory, IFPMM} from "./interfaces/IFPMM.sol";
import {IUMAOracleAdapter} from "./interfaces/IUMAOracleAdapter.sol";
import {FixedProductMarketMaker} from "./FPMMFactory.sol";

/// @title PredictionMarket
/// @notice Core prediction market contract. Orchestrates conditional tokens,
///         FPMM liquidity, and UMA oracle resolution for binary prediction markets.
///         Collateral: USDC (6 decimals). Outcome tokens: 18 decimals.
contract PredictionMarket is Ownable, Pausable, ReentrancyGuard, IERC1155Receiver {
    using SafeERC20 for IERC20;

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

    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);

    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error MarketNotFound();
    error MarketNotActive();
    error MarketAlreadyExists();
    error MarketNotPendingResolution();
    error MarketAlreadyResolved();
    error InvalidResolutionTime();
    error InsufficientInitialLiquidity();
    error InvalidOutcomeIndex();
    error ZeroAmount();
    error ZeroAddress();
    error InvalidFee();
    error OnlyOracleAdapter();
    error InvalidPayouts();
    error NothingToRedeem();

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant INITIAL_LIQUIDITY_REQUIRED = 100e6; // 100 USDC
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant FPMM_FEE_BPS = 200; // 2% FPMM trading fee
    uint256 public constant OUTCOME_COUNT = 2; // binary markets only

    // Polygon USDC address
    address public constant POLYGON_USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

    // ─── State ────────────────────────────────────────────────────────────────

    IERC20 public immutable usdc;
    IConditionalTokens public immutable conditionalTokens;
    IFPMMFactory public immutable fpmmFactory;
    IUMAOracleAdapter public immutable oracleAdapter;

    uint256 public protocolFeeBps; // e.g. 50 = 0.5%
    address public feeRecipient;

    mapping(bytes32 => MarketInfo) public markets;

    /// @notice Track USDC deposited per market per user (for cancel refunds)
    mapping(bytes32 => mapping(address => uint256)) public usdcDeposited;

    /// @dev Index sets for binary market: [1, 2] — initialized in constructor
    uint256[] internal _indexSets;

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _usdc USDC token address (use POLYGON_USDC on mainnet)
    /// @param _conditionalTokens ConditionalTokens contract address
    /// @param _fpmmFactory FPMMFactory contract address
    /// @param _oracleAdapter UMAOracleAdapter contract address
    /// @param _feeRecipient Address to receive protocol fees
    /// @param _owner Contract owner
    constructor(
        address _usdc,
        address _conditionalTokens,
        address _fpmmFactory,
        address _oracleAdapter,
        address _feeRecipient,
        address _owner
    ) Ownable(_owner) {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_conditionalTokens == address(0)) revert ZeroAddress();
        if (_fpmmFactory == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();

        usdc = IERC20(_usdc);
        conditionalTokens = IConditionalTokens(_conditionalTokens);
        fpmmFactory = IFPMMFactory(_fpmmFactory);
        oracleAdapter = IUMAOracleAdapter(_oracleAdapter);
        feeRecipient = _feeRecipient;
        protocolFeeBps = 50; // 0.5%

        _indexSets = new uint256[](2);
        _indexSets[0] = 1; // YES
        _indexSets[1] = 2; // NO
    }

    // ─── Market Lifecycle ─────────────────────────────────────────────────────

    /// @notice Create a new binary prediction market.
    /// @param questionId Unique identifier for the question
    /// @param question Human-readable market question
    /// @param ipfsHash IPFS CID of market metadata JSON
    /// @param resolutionTime Unix timestamp when the market can be resolved
    /// @param initialLiquidity Initial USDC liquidity to bootstrap the FPMM (min 100 USDC)
    /// @return conditionId The condition ID for this market
    function createMarket(
        bytes32 questionId,
        string calldata question,
        string calldata ipfsHash,
        uint256 resolutionTime,
        uint256 initialLiquidity
    ) external whenNotPaused nonReentrant returns (bytes32 conditionId) {
        if (resolutionTime <= block.timestamp) revert InvalidResolutionTime();
        if (initialLiquidity < INITIAL_LIQUIDITY_REQUIRED) revert InsufficientInitialLiquidity();

        // Compute condition ID using this contract as oracle
        conditionId = conditionalTokens.getConditionId(address(oracleAdapter), questionId, OUTCOME_COUNT);

        if (markets[conditionId].createdAt != 0) revert MarketAlreadyExists();

        // Prepare the condition
        conditionalTokens.prepareCondition(address(oracleAdapter), questionId, OUTCOME_COUNT);

        // Deploy FPMM for this market
        address fpmm = fpmmFactory.createFPMM(usdc, conditionalTokens, conditionId, FPMM_FEE_BPS);

        // Store market info
        markets[conditionId] = MarketInfo({
            conditionId: conditionId,
            fpmm: fpmm,
            clob: address(0), // CLOB deployed separately
            question: question,
            ipfsHash: ipfsHash,
            createdAt: block.timestamp,
            resolutionTime: resolutionTime,
            status: MarketStatus.Active,
            creator: msg.sender
        });

        // Transfer initial liquidity from creator and add to FPMM
        usdc.safeTransferFrom(msg.sender, address(this), initialLiquidity);
        usdcDeposited[conditionId][msg.sender] += initialLiquidity;

        // Approve and add funding to FPMM
        usdc.safeIncreaseAllowance(fpmm, initialLiquidity);
        uint256[] memory distributionHint = new uint256[](0);
        (uint256 lpShares,) = FixedProductMarketMaker(fpmm).addFunding(initialLiquidity, distributionHint);

        // Send LP shares to creator
        IERC20(fpmm).transfer(msg.sender, lpShares);

        emit MarketCreated(conditionId, msg.sender, question, ipfsHash, resolutionTime);
        emit LiquidityAdded(conditionId, msg.sender, initialLiquidity, lpShares);
    }

    /// @notice Add liquidity to an active market's FPMM.
    /// @param conditionId The market condition ID
    /// @param amount USDC amount to add
    function addLiquidity(bytes32 conditionId, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        MarketInfo storage market = _requireActiveMarket(conditionId);

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        usdcDeposited[conditionId][msg.sender] += amount;

        usdc.safeIncreaseAllowance(market.fpmm, amount);
        uint256[] memory distributionHint = new uint256[](0);
        (uint256 lpShares,) = FixedProductMarketMaker(market.fpmm).addFunding(amount, distributionHint);

        // Transfer LP shares directly to provider
        IERC20(market.fpmm).transfer(msg.sender, lpShares);

        emit LiquidityAdded(conditionId, msg.sender, amount, lpShares);
    }

    /// @notice Remove liquidity from an active market's FPMM.
    /// @param conditionId The market condition ID
    /// @param lpShares Number of LP shares to burn
    function removeLiquidity(bytes32 conditionId, uint256 lpShares) external whenNotPaused nonReentrant {
        if (lpShares == 0) revert ZeroAmount();
        MarketInfo storage market = _requireActiveMarket(conditionId);

        // Transfer LP shares from caller to here, then call removeFunding
        IERC20(market.fpmm).transferFrom(msg.sender, address(this), lpShares);

        uint256[] memory sendAmounts = FixedProductMarketMaker(market.fpmm).removeFunding(lpShares);

        // FPMM sends collateral/tokens back to this contract; forward to user
        // Transfer outcome tokens that came back
        for (uint256 i = 0; i < sendAmounts.length; i++) {
            if (sendAmounts[i] > 0) {
                bytes32 collectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, _indexSets[i]);
                uint256 positionId = uint256(conditionalTokens.getPositionId(usdc, collectionId));
                uint256 balance = conditionalTokens.balanceOf(address(this), positionId);
                if (balance > 0) {
                    conditionalTokens.safeTransferFrom(address(this), msg.sender, positionId, balance, "");
                }
            }
        }

        // Forward any USDC that came back
        uint256 usdcBalance = usdc.balanceOf(address(this));
        if (usdcBalance > 0) {
            usdc.safeTransfer(msg.sender, usdcBalance);
        }

        emit LiquidityRemoved(conditionId, msg.sender, lpShares, sendAmounts);
    }

    // ─── Trading ──────────────────────────────────────────────────────────────

    /// @notice Buy outcome tokens via the FPMM.
    /// @param conditionId The market condition ID
    /// @param outcomeIndex 0=YES, 1=NO
    /// @param usdcAmount Amount of USDC to spend (including protocol fee)
    /// @param minTokens Minimum outcome tokens to receive (slippage guard)
    /// @return tokensBought Number of outcome tokens received
    function buyOutcome(bytes32 conditionId, uint256 outcomeIndex, uint256 usdcAmount, uint256 minTokens)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tokensBought)
    {
        if (usdcAmount == 0) revert ZeroAmount();
        if (outcomeIndex >= OUTCOME_COUNT) revert InvalidOutcomeIndex();
        MarketInfo storage market = _requireActiveMarket(conditionId);

        // Collect USDC from buyer
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Deduct protocol fee
        uint256 protocolFee = (usdcAmount * protocolFeeBps) / BPS_DENOMINATOR;
        uint256 netAmount = usdcAmount - protocolFee;

        if (protocolFee > 0) {
            usdc.safeTransfer(feeRecipient, protocolFee);
        }

        // Buy via FPMM
        usdc.safeIncreaseAllowance(market.fpmm, netAmount);
        tokensBought = FixedProductMarketMaker(market.fpmm).buy(netAmount, outcomeIndex, minTokens);

        // Transfer outcome tokens to buyer
        bytes32 collectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, _indexSets[outcomeIndex]);
        uint256 positionId = uint256(conditionalTokens.getPositionId(usdc, collectionId));
        conditionalTokens.safeTransferFrom(address(this), msg.sender, positionId, tokensBought, "");

        usdcDeposited[conditionId][msg.sender] += netAmount;

        emit OutcomeBought(conditionId, msg.sender, outcomeIndex, usdcAmount, tokensBought);
    }

    /// @notice Sell outcome tokens via the FPMM.
    /// @param conditionId The market condition ID
    /// @param outcomeIndex 0=YES, 1=NO
    /// @param returnAmount Amount of USDC to receive (before protocol fee)
    /// @param maxTokens Maximum outcome tokens to sell (slippage guard)
    /// @return tokensSold Number of outcome tokens spent
    function sellOutcome(bytes32 conditionId, uint256 outcomeIndex, uint256 returnAmount, uint256 maxTokens)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tokensSold)
    {
        if (returnAmount == 0) revert ZeroAmount();
        if (outcomeIndex >= OUTCOME_COUNT) revert InvalidOutcomeIndex();
        MarketInfo storage market = _requireActiveMarket(conditionId);

        // Calculate how many tokens needed (before calling sell)
        tokensSold = FixedProductMarketMaker(market.fpmm).calcSellAmount(returnAmount, outcomeIndex);
        if (tokensSold > maxTokens) revert InvalidOutcomeIndex(); // slippage

        // Transfer outcome tokens from seller to here
        bytes32 collectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, _indexSets[outcomeIndex]);
        uint256 positionId = uint256(conditionalTokens.getPositionId(usdc, collectionId));
        conditionalTokens.safeTransferFrom(msg.sender, address(this), positionId, tokensSold, "");

        // Approve FPMM to use our outcome tokens and execute sell
        conditionalTokens.setApprovalForAll(market.fpmm, true);
        FixedProductMarketMaker(market.fpmm).sell(returnAmount, outcomeIndex, tokensSold);

        // Deduct protocol fee from received USDC
        uint256 protocolFee = (returnAmount * protocolFeeBps) / BPS_DENOMINATOR;
        uint256 netReturn = returnAmount - protocolFee;

        if (protocolFee > 0) {
            usdc.safeTransfer(feeRecipient, protocolFee);
        }

        usdc.safeTransfer(msg.sender, netReturn);

        emit OutcomeSold(conditionId, msg.sender, outcomeIndex, returnAmount, tokensSold);
    }

    // ─── Resolution ───────────────────────────────────────────────────────────

    /// @notice Initiate the UMA oracle resolution process.
    ///         Can be called by anyone after the resolution time.
    /// @param conditionId The market condition ID
    function initiateResolution(bytes32 conditionId) external {
        MarketInfo storage market = markets[conditionId];
        if (market.createdAt == 0) revert MarketNotFound();
        if (market.status != MarketStatus.Active) revert MarketNotActive();
        if (block.timestamp < market.resolutionTime) revert InvalidResolutionTime();

        market.status = MarketStatus.PendingResolution;
    }

    /// @notice Resolve market with final payouts. Called by oracle adapter after UMA settles.
    /// @param conditionId The market condition ID
    /// @param payouts Payout numerators (e.g. [1,0] for YES wins, [0,1] for NO wins)
    function resolveMarket(bytes32 conditionId, uint256[] calldata payouts) external {
        if (msg.sender != address(oracleAdapter)) revert OnlyOracleAdapter();

        MarketInfo storage market = markets[conditionId];
        if (market.createdAt == 0) revert MarketNotFound();
        if (market.status == MarketStatus.Resolved) revert MarketAlreadyResolved();
        if (payouts.length != OUTCOME_COUNT) revert InvalidPayouts();

        uint256 payoutSum = 0;
        for (uint256 i = 0; i < payouts.length; i++) {
            payoutSum += payouts[i];
        }
        if (payoutSum == 0) revert InvalidPayouts();

        market.status = MarketStatus.Resolved;

        // Report payouts to conditional tokens (oracle adapter calls this)
        // The oracle adapter has already called reportPayouts on ConditionalTokens

        emit MarketResolved(conditionId, payouts);
    }

    /// @notice Cancel a market and refund initial liquidity. Owner only.
    /// @param conditionId The market condition ID
    function cancelMarket(bytes32 conditionId) external onlyOwner {
        MarketInfo storage market = markets[conditionId];
        if (market.createdAt == 0) revert MarketNotFound();
        if (market.status == MarketStatus.Resolved) revert MarketAlreadyResolved();
        if (market.status == MarketStatus.Cancelled) revert MarketAlreadyResolved();

        market.status = MarketStatus.Cancelled;

        emit MarketCancelled(conditionId);
    }

    /// @notice Redeem winning positions after market resolution.
    /// @param conditionId The resolved market condition ID
    function redeemPositions(bytes32 conditionId) external nonReentrant {
        MarketInfo storage market = markets[conditionId];
        if (market.createdAt == 0) revert MarketNotFound();
        if (market.status != MarketStatus.Resolved) revert MarketNotActive();

        uint256 balanceBefore = usdc.balanceOf(msg.sender);

        // Determine which positions the user holds and redeem them
        uint256[] memory indexSetsToRedeem = new uint256[](OUTCOME_COUNT);
        bool hasPositions = false;

        for (uint256 i = 0; i < OUTCOME_COUNT; i++) {
            bytes32 collectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, _indexSets[i]);
            uint256 positionId = uint256(conditionalTokens.getPositionId(usdc, collectionId));
            uint256 balance = conditionalTokens.balanceOf(msg.sender, positionId);

            if (balance > 0) {
                indexSetsToRedeem[i] = _indexSets[i];
                hasPositions = true;
                // Transfer tokens to this contract for redemption
                conditionalTokens.safeTransferFrom(msg.sender, address(this), positionId, balance, "");
            }
        }

        if (!hasPositions) revert NothingToRedeem();

        // Build actual indexSets to pass (filter zeros)
        uint256 count = 0;
        for (uint256 i = 0; i < OUTCOME_COUNT; i++) {
            if (indexSetsToRedeem[i] != 0) count++;
        }

        uint256[] memory finalIndexSets = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < OUTCOME_COUNT; i++) {
            if (indexSetsToRedeem[i] != 0) {
                finalIndexSets[j++] = indexSetsToRedeem[i];
            }
        }

        // Redeem positions - collateral goes to this contract
        conditionalTokens.redeemPositions(usdc, bytes32(0), conditionId, finalIndexSets);

        // Forward payout to user
        uint256 payout = usdc.balanceOf(address(this));
        if (payout > 0) {
            usdc.safeTransfer(msg.sender, payout);
        }

        uint256 actualPayout = usdc.balanceOf(msg.sender) - balanceBefore;

        emit PositionsRedeemed(conditionId, msg.sender, actualPayout);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /// @notice Update protocol fee. Max 500 bps (5%).
    function setProtocolFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > 500) revert InvalidFee();
        emit ProtocolFeeUpdated(protocolFeeBps, newFeeBps);
        protocolFeeBps = newFeeBps;
    }

    /// @notice Update fee recipient address.
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    function getMarket(bytes32 conditionId) external view returns (MarketInfo memory) {
        return markets[conditionId];
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

    function _requireActiveMarket(bytes32 conditionId) internal view returns (MarketInfo storage market) {
        market = markets[conditionId];
        if (market.createdAt == 0) revert MarketNotFound();
        if (market.status != MarketStatus.Active) revert MarketNotActive();
    }
}
