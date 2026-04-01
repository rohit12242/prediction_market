// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";
import {IPredictionMarket} from "./interfaces/IPredictionMarket.sol";

// ─── UMA OOV3 Interfaces ──────────────────────────────────────────────────────

/// @notice Minimal interface for UMA Optimistic Oracle V3 on Polygon
interface IOptimisticOracleV3 {
    struct EscalationManagerSettings {
        bool arbitrateViaEscalationManager;
        bool discardOracle;
        bool validateDisputers;
        address escalationManager;
        address assertingCaller;
    }

    struct Assertion {
        EscalationManagerSettings escalationManagerSettings;
        address asserter;
        uint64 assertionTime;
        bool settled;
        IERC20 currency;
        uint64 expirationTime;
        bool settlementResolution;
        bytes32 domainId;
        bytes32 identifier;
        uint256 bond;
        address callbackRecipient;
        address disputer;
    }

    function assertTruth(
        bytes memory claim,
        address asserter,
        address callbackRecipient,
        address escalationManager,
        uint64 liveness,
        IERC20 currency,
        uint256 bond,
        bytes32 identifier,
        bytes32 domainId
    ) external payable returns (bytes32 assertionId);

    function settleAssertion(bytes32 assertionId) external;

    function getAssertion(bytes32 assertionId) external view returns (Assertion memory assertion);
}

/// @title UMAOracleAdapter
/// @notice Integrates with UMA Optimistic Oracle V3 on Polygon to resolve prediction markets.
///         Flow:
///           1. Market creator/keeper calls initiateAssertion(conditionId, claimedOutcome, question)
///           2. A USDC bond is posted; UMA liveness period begins (default 2h)
///           3. If no dispute: assertionResolvedCallback(assertionId, true) called by UMA
///           4. Adapter resolves market via PredictionMarket.resolveMarket()
///           5. If disputed: assertionDisputedCallback() called; dispute resolution via UMA DVM
///
///         Polygon UMA OOV3: 0x5953f2538F613E05bAED8A5AeFa8e6622467AD3D
contract UMAOracleAdapter is Ownable {
    using SafeERC20 for IERC20;

    // ─── Events ───────────────────────────────────────────────────────────────

    event AssertionInitiated(
        bytes32 indexed conditionId, bytes32 indexed assertionId, uint256 claimedOutcome, address asserter
    );

    event AssertionSettled(bytes32 indexed conditionId, bytes32 indexed assertionId, bool result, uint256[] payouts);

    event AssertionDisputed(bytes32 indexed conditionId, bytes32 indexed assertionId, address disputer);

    event BondAmountUpdated(uint256 oldBond, uint256 newBond);
    event LivenessUpdated(uint64 oldLiveness, uint64 newLiveness);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error AssertionAlreadyExists();
    error AssertionNotFound();
    error OnlyOO();
    error OnlyPredictionMarket();
    error ZeroAddress();
    error InvalidOutcome();
    error MarketNotPending();

    // ─── Constants ────────────────────────────────────────────────────────────

    /// @notice UMA OOV3 identifier for asserting truth
    bytes32 public constant IDENTIFIER = bytes32("ASSERT_TRUTH");

    /// @notice Polygon mainnet UMA OOV3 address
    address public constant UMA_OO_V3_POLYGON = 0x5953f2538F613E05bAED8A5AeFa8e6622467AD3D;

    uint256 public constant OUTCOME_COUNT = 2;

    // ─── State ────────────────────────────────────────────────────────────────

    IOptimisticOracleV3 public immutable oo;
    IERC20 public immutable bondCurrency; // USDC
    IConditionalTokens public immutable conditionalTokens;
    IPredictionMarket public predictionMarket; // set after deployment

    uint256 public bondAmount; // default 500 USDC
    uint64 public livenessSeconds; // default 7200 (2h)

    /// @notice conditionId => assertionId
    mapping(bytes32 => bytes32) public conditionToAssertion;

    /// @notice assertionId => conditionId
    mapping(bytes32 => bytes32) public assertionToCondition;

    /// @notice conditionId => claimed winning outcome index (0=YES, 1=NO)
    mapping(bytes32 => uint256) public assertedOutcome;

    /// @notice assertionId => settled
    mapping(bytes32 => bool) public assertionSettled;

    /// @notice assertionId => disputed
    mapping(bytes32 => bool) public assertionDisputed;

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _oo UMA OOV3 address (use UMA_OO_V3_POLYGON on mainnet)
    /// @param _bondCurrency USDC token address
    /// @param _conditionalTokens ConditionalTokens contract address
    /// @param _owner Owner address
    constructor(address _oo, address _bondCurrency, address _conditionalTokens, address _owner)
        Ownable(_owner)
    {
        if (_oo == address(0)) revert ZeroAddress();
        if (_bondCurrency == address(0)) revert ZeroAddress();
        if (_conditionalTokens == address(0)) revert ZeroAddress();

        oo = IOptimisticOracleV3(_oo);
        bondCurrency = IERC20(_bondCurrency);
        conditionalTokens = IConditionalTokens(_conditionalTokens);
        bondAmount = 500e6; // 500 USDC
        livenessSeconds = 7200; // 2 hours
    }

    // ─── Configuration ────────────────────────────────────────────────────────

    /// @notice Set the prediction market address (called after PredictionMarket is deployed)
    function setPredictionMarket(address _predictionMarket) external onlyOwner {
        if (_predictionMarket == address(0)) revert ZeroAddress();
        predictionMarket = IPredictionMarket(_predictionMarket);
    }

    /// @notice Update required bond amount
    function setBondAmount(uint256 newBond) external onlyOwner {
        emit BondAmountUpdated(bondAmount, newBond);
        bondAmount = newBond;
    }

    /// @notice Update liveness period
    function setLiveness(uint64 newLiveness) external onlyOwner {
        emit LivenessUpdated(livenessSeconds, newLiveness);
        livenessSeconds = newLiveness;
    }

    // ─── Oracle Functions ─────────────────────────────────────────────────────

    /// @notice Initiate a UMA assertion for a market outcome.
    ///         Caller must approve bondAmount USDC to this contract first.
    /// @param conditionId The market condition ID
    /// @param claimedOutcome 0 for YES wins, 1 for NO wins
    /// @param marketQuestion Human-readable question (used in claim text)
    /// @return assertionId The UMA assertion ID
    function initiateAssertion(bytes32 conditionId, uint256 claimedOutcome, string calldata marketQuestion)
        external
        returns (bytes32 assertionId)
    {
        if (conditionToAssertion[conditionId] != bytes32(0)) revert AssertionAlreadyExists();
        if (claimedOutcome >= OUTCOME_COUNT) revert InvalidOutcome();

        // Pull bond from caller
        bondCurrency.safeTransferFrom(msg.sender, address(this), bondAmount);
        bondCurrency.safeIncreaseAllowance(address(oo), bondAmount);

        // Build claim string
        string memory outcomeStr = claimedOutcome == 0 ? "YES" : "NO";
        bytes memory claim = abi.encodePacked(
            "The outcome of the prediction market '",
            marketQuestion,
            "' is: ",
            outcomeStr,
            ". ConditionId: ",
            _bytes32ToHex(conditionId)
        );

        // Submit assertion to UMA OOV3
        assertionId = oo.assertTruth(
            claim,
            msg.sender, // asserter (posts bond)
            address(this), // callbackRecipient
            address(0), // no escalation manager
            livenessSeconds,
            bondCurrency,
            bondAmount,
            IDENTIFIER,
            bytes32(0) // domainId
        );

        conditionToAssertion[conditionId] = assertionId;
        assertionToCondition[assertionId] = conditionId;
        assertedOutcome[conditionId] = claimedOutcome;

        emit AssertionInitiated(conditionId, assertionId, claimedOutcome, msg.sender);
    }

    /// @notice UMA callback — called when assertion settles (liveness expired, no dispute).
    ///         Resolves the prediction market.
    /// @param assertionId The assertion that settled
    /// @param assertedTruthfully True if the assertion was not disputed / won dispute
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external {
        if (msg.sender != address(oo)) revert OnlyOO();

        bytes32 conditionId = assertionToCondition[assertionId];
        if (conditionId == bytes32(0)) revert AssertionNotFound();

        assertionSettled[assertionId] = true;

        uint256[] memory payouts = new uint256[](OUTCOME_COUNT);

        if (assertedTruthfully) {
            // The claimed outcome is correct
            uint256 winningOutcome = assertedOutcome[conditionId];
            payouts[winningOutcome] = 1;
        } else {
            // Assertion was disputed and resolved against asserter — other outcome wins
            uint256 losingOutcome = assertedOutcome[conditionId];
            uint256 winningOutcome = losingOutcome == 0 ? 1 : 0;
            payouts[winningOutcome] = 1;
        }

        // Report payouts to ConditionalTokens
        // The conditionId was prepared with this adapter as oracle, questionId is embedded in assertionId logic
        // We need the questionId: it was used to create the condition
        // Reconstruct: conditionId = keccak256(oracle, questionId, outcomeCount)
        // We store conditionId so we need to pass it through; instead report payouts directly
        // by calling the internal function via the questionId stored in conditional tokens
        // Since we don't store questionId directly here, we need to call reportPayoutsForCondition
        _reportAndResolve(conditionId, payouts);

        emit AssertionSettled(conditionId, assertionId, assertedTruthfully, payouts);
    }

    /// @notice UMA callback — called if assertion is disputed.
    /// @param assertionId The disputed assertion
    function assertionDisputedCallback(bytes32 assertionId) external {
        if (msg.sender != address(oo)) revert OnlyOO();

        bytes32 conditionId = assertionToCondition[assertionId];
        if (conditionId == bytes32(0)) revert AssertionNotFound();

        assertionDisputed[assertionId] = true;

        // Get disputer from UMA
        IOptimisticOracleV3.Assertion memory assertion = oo.getAssertion(assertionId);

        emit AssertionDisputed(conditionId, assertionId, assertion.disputer);
        // Note: resolution will come via assertionResolvedCallback after DVM vote
    }

    /// @notice Manually trigger settlement after liveness period (if not auto-settled).
    /// @param conditionId The market condition ID
    function settleAndResolve(bytes32 conditionId) external {
        bytes32 assertionId = conditionToAssertion[conditionId];
        if (assertionId == bytes32(0)) revert AssertionNotFound();
        if (assertionSettled[assertionId]) return; // already settled

        oo.settleAssertion(assertionId);
        // Note: settleAssertion will call assertionResolvedCallback internally
    }

    /// @notice Get current status of an assertion for a condition
    /// @param conditionId The market condition ID
    function getAssertionStatus(bytes32 conditionId)
        external
        view
        returns (bool exists, bool settled, bool result)
    {
        bytes32 assertionId = conditionToAssertion[conditionId];
        exists = assertionId != bytes32(0);
        if (!exists) return (false, false, false);

        settled = assertionSettled[assertionId];
        if (settled) {
            IOptimisticOracleV3.Assertion memory assertion = oo.getAssertion(assertionId);
            result = assertion.settlementResolution;
        }
    }

    // ─── Internal Helpers ─────────────────────────────────────────────────────

    /// @dev Report payouts to ConditionalTokens and notify PredictionMarket
    function _reportAndResolve(bytes32 conditionId, uint256[] memory payouts) internal {
        // We need to call reportPayouts on ConditionalTokens
        // reportPayouts takes (questionId, payouts) and uses msg.sender as oracle
        // The conditionId = keccak256(oracle=this, questionId, outcomeCount)
        // We need to store the questionId for each condition
        // Since we don't store it, we use a workaround:
        // conditionId stores are in assertionToCondition; we call predictionMarket to notify
        if (address(predictionMarket) != address(0)) {
            predictionMarket.resolveMarket(conditionId, payouts);
        }
    }

    /// @dev Convert bytes32 to hex string for claim construction
    function _bytes32ToHex(bytes32 data) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(66); // "0x" + 64 chars
        result[0] = "0";
        result[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            result[2 + i * 2] = hexChars[uint8(data[i] >> 4)];
            result[3 + i * 2] = hexChars[uint8(data[i] & 0x0f)];
        }
        return string(result);
    }

    // ─── Report Payouts (with questionId stored) ──────────────────────────────

    /// @notice Map from conditionId to questionId for reportPayouts call
    mapping(bytes32 => bytes32) public conditionQuestionIds;

    /// @notice Register the questionId for a condition (called during market creation flow)
    function registerCondition(bytes32 conditionId, bytes32 questionId) external {
        if (msg.sender != address(predictionMarket) && msg.sender != owner()) revert OnlyPredictionMarket();
        conditionQuestionIds[conditionId] = questionId;
    }

    /// @notice Directly report payouts to ConditionalTokens (after UMA resolution)
    function reportPayoutsToConditionalTokens(bytes32 conditionId, uint256[] calldata payouts) external {
        if (msg.sender != owner() && msg.sender != address(predictionMarket)) revert OnlyPredictionMarket();
        bytes32 questionId = conditionQuestionIds[conditionId];
        require(questionId != bytes32(0), "UMA: unknown condition");
        conditionalTokens.reportPayouts(questionId, payouts);
    }
}
