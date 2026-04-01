// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUMAOracleAdapter
/// @notice Interface for the UMA Optimistic Oracle V3 adapter
interface IUMAOracleAdapter {
    // ─── Events ───────────────────────────────────────────────────────────────

    event AssertionInitiated(
        bytes32 indexed conditionId, bytes32 indexed assertionId, uint256 claimedOutcome, address asserter
    );

    event AssertionSettled(bytes32 indexed conditionId, bytes32 indexed assertionId, bool result, uint256[] payouts);

    event AssertionDisputed(bytes32 indexed conditionId, bytes32 indexed assertionId, address disputer);

    // ─── Functions ────────────────────────────────────────────────────────────

    function initiateAssertion(bytes32 conditionId, uint256 claimedOutcome, string calldata marketQuestion)
        external
        returns (bytes32 assertionId);

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;

    function assertionDisputedCallback(bytes32 assertionId) external;

    function settleAndResolve(bytes32 conditionId) external;

    function getAssertionStatus(bytes32 conditionId)
        external
        view
        returns (bool exists, bool settled, bool result);
}
