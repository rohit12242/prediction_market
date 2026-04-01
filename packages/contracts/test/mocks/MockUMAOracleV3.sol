// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockUMAOracleV3
/// @notice Mock UMA Optimistic Oracle V3 for testing.
///         Allows test harness to control assertion outcomes.
contract MockUMAOracleV3 {
    using SafeERC20 for IERC20;

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

    // ─── State ────────────────────────────────────────────────────────────────

    mapping(bytes32 => Assertion) public assertions;
    uint256 public assertionCount;

    // ─── Events ───────────────────────────────────────────────────────────────

    event AssertionMade(bytes32 indexed assertionId, address indexed asserter, bytes claim);
    event AssertionSettled(bytes32 indexed assertionId, bool resolution);
    event AssertionDisputed(bytes32 indexed assertionId, address indexed disputer);

    // ─── Functions ────────────────────────────────────────────────────────────

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
    ) external payable returns (bytes32 assertionId) {
        assertionId = keccak256(abi.encode(asserter, ++assertionCount, block.timestamp));

        // Pull bond
        currency.safeTransferFrom(msg.sender, address(this), bond);

        assertions[assertionId] = Assertion({
            escalationManagerSettings: EscalationManagerSettings({
                arbitrateViaEscalationManager: false,
                discardOracle: false,
                validateDisputers: false,
                escalationManager: escalationManager,
                assertingCaller: msg.sender
            }),
            asserter: asserter,
            assertionTime: uint64(block.timestamp),
            settled: false,
            currency: currency,
            expirationTime: uint64(block.timestamp) + liveness,
            settlementResolution: false,
            domainId: domainId,
            identifier: identifier,
            bond: bond,
            callbackRecipient: callbackRecipient,
            disputer: address(0)
        });

        emit AssertionMade(assertionId, asserter, claim);
    }

    /// @notice Settle an assertion as truthful (no dispute, liveness expired)
    function settleAssertion(bytes32 assertionId) external {
        Assertion storage a = assertions[assertionId];
        require(!a.settled, "MockUMA: already settled");

        a.settled = true;
        a.settlementResolution = (a.disputer == address(0)); // true if not disputed

        // Refund bond to asserter
        a.currency.safeTransfer(a.asserter, a.bond);

        emit AssertionSettled(assertionId, a.settlementResolution);

        // Callback
        if (a.callbackRecipient != address(0)) {
            ICallback(a.callbackRecipient).assertionResolvedCallback(assertionId, a.settlementResolution);
        }
    }

    /// @notice Test helper: settle with explicit resolution
    function settleAssertionWithResult(bytes32 assertionId, bool resolution) external {
        Assertion storage a = assertions[assertionId];
        require(!a.settled, "MockUMA: already settled");

        a.settled = true;
        a.settlementResolution = resolution;

        // Refund bond
        a.currency.safeTransfer(a.asserter, a.bond);

        emit AssertionSettled(assertionId, resolution);

        if (a.callbackRecipient != address(0)) {
            ICallback(a.callbackRecipient).assertionResolvedCallback(assertionId, resolution);
        }
    }

    /// @notice Test helper: dispute an assertion
    function disputeAssertion(bytes32 assertionId, address disputer) external {
        Assertion storage a = assertions[assertionId];
        require(!a.settled, "MockUMA: already settled");
        require(a.disputer == address(0), "MockUMA: already disputed");

        a.disputer = disputer;

        emit AssertionDisputed(assertionId, disputer);

        if (a.callbackRecipient != address(0)) {
            ICallback(a.callbackRecipient).assertionDisputedCallback(assertionId);
        }
    }

    function getAssertion(bytes32 assertionId) external view returns (Assertion memory) {
        return assertions[assertionId];
    }
}

interface ICallback {
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;
    function assertionDisputedCallback(bytes32 assertionId) external;
}
