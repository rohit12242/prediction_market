// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {UMAOracleAdapter} from "../src/UMAOracleAdapter.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {FPMMFactory} from "../src/FPMMFactory.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockUMAOracleV3} from "./mocks/MockUMAOracleV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract UMAOracleAdapterTest is Test {
    ConditionalTokens public ct;
    FPMMFactory public fpmmFactory;
    UMAOracleAdapter public adapter;
    PredictionMarket public pm;
    ERC20Mock public usdc;
    MockUMAOracleV3 public mockOO;

    address public owner = address(uint160(0xABCD));
    address public feeRecipient = address(uint160(0xFEE5));
    address public alice = address(uint160(0xA1CE));
    address public bob = address(uint160(0xB0B5));
    address public asserter = address(uint160(0xA553));

    bytes32 public questionId = keccak256("Will BTC reach $200k?");
    string public marketQuestion = "Will BTC reach $200k?";
    bytes32 public conditionId;

    uint256 public constant BOND_AMOUNT = 500e6;
    uint256 public constant INITIAL_LIQUIDITY = 100e6;

    function setUp() public {
        ct = new ConditionalTokens();
        fpmmFactory = new FPMMFactory();
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        mockOO = new MockUMAOracleV3();

        adapter = new UMAOracleAdapter(address(mockOO), address(usdc), address(ct), owner);

        pm = new PredictionMarket(
            address(usdc), address(ct), address(fpmmFactory), address(adapter), feeRecipient, owner
        );

        vm.prank(owner);
        adapter.setPredictionMarket(address(pm));

        // Mint USDC
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(asserter, 1_000_000e6);

        // Create a market for testing
        conditionId = ct.getConditionId(address(adapter), questionId, 2);
        vm.startPrank(alice);
        usdc.approve(address(pm), INITIAL_LIQUIDITY);
        pm.createMarket(questionId, marketQuestion, "QmTest", block.timestamp + 30 days, INITIAL_LIQUIDITY);
        vm.stopPrank();

        // Register condition in adapter
        vm.prank(owner);
        adapter.registerCondition(conditionId, questionId);
    }

    // ─── setPredictionMarket ──────────────────────────────────────────────────

    function test_setPredictionMarket() public view {
        assertEq(address(adapter.predictionMarket()), address(pm));
    }

    function test_setPredictionMarket_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setPredictionMarket(address(0x1234));
    }

    function test_setPredictionMarket_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(UMAOracleAdapter.ZeroAddress.selector);
        adapter.setPredictionMarket(address(0));
    }

    // ─── initiateAssertion ────────────────────────────────────────────────────

    function test_initiateAssertion_yesOutcome() public {
        vm.startPrank(asserter);
        usdc.approve(address(adapter), BOND_AMOUNT);
        bytes32 assertionId = adapter.initiateAssertion(conditionId, 0, marketQuestion);
        vm.stopPrank();

        assertTrue(assertionId != bytes32(0));
        assertEq(adapter.conditionToAssertion(conditionId), assertionId);
        assertEq(adapter.assertionToCondition(assertionId), conditionId);
        assertEq(adapter.assertedOutcome(conditionId), 0); // YES
    }

    function test_initiateAssertion_noOutcome() public {
        vm.startPrank(asserter);
        usdc.approve(address(adapter), BOND_AMOUNT);
        bytes32 assertionId = adapter.initiateAssertion(conditionId, 1, marketQuestion);
        vm.stopPrank();

        assertEq(adapter.assertedOutcome(conditionId), 1); // NO
        assertTrue(assertionId != bytes32(0));
    }

    function test_initiateAssertion_emitsEvent() public {
        vm.startPrank(asserter);
        usdc.approve(address(adapter), BOND_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit UMAOracleAdapter.AssertionInitiated(conditionId, bytes32(0), 0, asserter);
        adapter.initiateAssertion(conditionId, 0, marketQuestion);
        vm.stopPrank();
    }

    function test_initiateAssertion_revert_invalidOutcome() public {
        vm.startPrank(asserter);
        usdc.approve(address(adapter), BOND_AMOUNT);
        vm.expectRevert(UMAOracleAdapter.InvalidOutcome.selector);
        adapter.initiateAssertion(conditionId, 5, marketQuestion);
        vm.stopPrank();
    }

    function test_initiateAssertion_revert_doubleAssertion() public {
        vm.startPrank(asserter);
        usdc.approve(address(adapter), BOND_AMOUNT * 2);
        adapter.initiateAssertion(conditionId, 0, marketQuestion);

        vm.expectRevert(UMAOracleAdapter.AssertionAlreadyExists.selector);
        adapter.initiateAssertion(conditionId, 0, marketQuestion);
        vm.stopPrank();
    }

    // ─── assertionResolvedCallback ────────────────────────────────────────────

    function test_assertionResolvedCallback_yesWins_truthfully() public {
        // Initiate assertion for YES
        vm.startPrank(asserter);
        usdc.approve(address(adapter), BOND_AMOUNT);
        bytes32 assertionId = adapter.initiateAssertion(conditionId, 0, marketQuestion);
        vm.stopPrank();

        // UMA settles truthfully → YES wins
        vm.prank(address(mockOO));
        adapter.assertionResolvedCallback(assertionId, true);

        assertTrue(adapter.assertionSettled(assertionId));

        // Market should be resolved
        PredictionMarket.MarketInfo memory market = pm.getMarket(conditionId);
        assertEq(uint8(market.status), uint8(PredictionMarket.MarketStatus.Resolved));
    }

    function test_assertionResolvedCallback_noWins_notTruthfully() public {
        // Asserter claims YES, but assertion resolves as false → NO wins
        vm.startPrank(asserter);
        usdc.approve(address(adapter), BOND_AMOUNT);
        bytes32 assertionId = adapter.initiateAssertion(conditionId, 0, marketQuestion);
        vm.stopPrank();

        vm.prank(address(mockOO));
        adapter.assertionResolvedCallback(assertionId, false);

        assertTrue(adapter.assertionSettled(assertionId));

        // Market resolved with NO winning
        PredictionMarket.MarketInfo memory market = pm.getMarket(conditionId);
        assertEq(uint8(market.status), uint8(PredictionMarket.MarketStatus.Resolved));
    }

    function test_assertionResolvedCallback_emitsEvent() public {
        vm.startPrank(asserter);
        usdc.approve(address(adapter), BOND_AMOUNT);
        bytes32 assertionId = adapter.initiateAssertion(conditionId, 0, marketQuestion);
        vm.stopPrank();

        vm.expectEmit(true, true, false, false);
        emit UMAOracleAdapter.AssertionSettled(conditionId, assertionId, true, new uint256[](0));

        vm.prank(address(mockOO));
        adapter.assertionResolvedCallback(assertionId, true);
    }

    function test_assertionResolvedCallback_revert_notOO() public {
        vm.startPrank(asserter);
        usdc.approve(address(adapter), BOND_AMOUNT);
        bytes32 assertionId = adapter.initiateAssertion(conditionId, 0, marketQuestion);
        vm.stopPrank();

        vm.prank(alice); // not OO
        vm.expectRevert(UMAOracleAdapter.OnlyOO.selector);
        adapter.assertionResolvedCallback(assertionId, true);
    }

    function test_assertionResolvedCallback_revert_unknownAssertion() public {
        vm.prank(address(mockOO));
        vm.expectRevert(UMAOracleAdapter.AssertionNotFound.selector);
        adapter.assertionResolvedCallback(bytes32(uint256(999)), true);
    }

    // ─── assertionDisputedCallback ────────────────────────────────────────────

    function test_assertionDisputedCallback() public {
        vm.startPrank(asserter);
        usdc.approve(address(adapter), BOND_AMOUNT);
        bytes32 assertionId = adapter.initiateAssertion(conditionId, 0, marketQuestion);
        vm.stopPrank();

        // Dispute via mockOO (sets disputer)
        mockOO.disputeAssertion(assertionId, bob);

        // assertionDisputedCallback should have been called
        assertTrue(adapter.assertionDisputed(assertionId));
    }

    function test_assertionDisputedCallback_revert_notOO() public {
        vm.startPrank(asserter);
        usdc.approve(address(adapter), BOND_AMOUNT);
        bytes32 assertionId = adapter.initiateAssertion(conditionId, 0, marketQuestion);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(UMAOracleAdapter.OnlyOO.selector);
        adapter.assertionDisputedCallback(assertionId);
    }

    // ─── settleAndResolve ─────────────────────────────────────────────────────

    function test_settleAndResolve() public {
        vm.startPrank(asserter);
        usdc.approve(address(adapter), BOND_AMOUNT);
        bytes32 assertionId = adapter.initiateAssertion(conditionId, 0, marketQuestion);
        vm.stopPrank();

        // Manually trigger settlement
        adapter.settleAndResolve(conditionId);

        // Assertion should be settled (mockOO calls the callback automatically)
        assertTrue(adapter.assertionSettled(assertionId));
    }

    function test_settleAndResolve_revert_noAssertion() public {
        vm.expectRevert(UMAOracleAdapter.AssertionNotFound.selector);
        adapter.settleAndResolve(bytes32(uint256(999)));
    }

    function test_settleAndResolve_noopIfAlreadySettled() public {
        vm.startPrank(asserter);
        usdc.approve(address(adapter), BOND_AMOUNT);
        bytes32 assertionId = adapter.initiateAssertion(conditionId, 0, marketQuestion);
        vm.stopPrank();

        adapter.settleAndResolve(conditionId);
        assertTrue(adapter.assertionSettled(assertionId));

        // Second call should not revert (noop)
        adapter.settleAndResolve(conditionId);
    }

    // ─── getAssertionStatus ───────────────────────────────────────────────────

    function test_getAssertionStatus_noAssertion() public view {
        (bool exists, bool settled, bool result) = adapter.getAssertionStatus(conditionId);
        assertFalse(exists);
        assertFalse(settled);
        assertFalse(result);
    }

    function test_getAssertionStatus_pending() public {
        vm.startPrank(asserter);
        usdc.approve(address(adapter), BOND_AMOUNT);
        adapter.initiateAssertion(conditionId, 0, marketQuestion);
        vm.stopPrank();

        (bool exists, bool settled,) = adapter.getAssertionStatus(conditionId);
        assertTrue(exists);
        assertFalse(settled);
    }

    function test_getAssertionStatus_settled() public {
        vm.startPrank(asserter);
        usdc.approve(address(adapter), BOND_AMOUNT);
        adapter.initiateAssertion(conditionId, 0, marketQuestion);
        vm.stopPrank();

        adapter.settleAndResolve(conditionId);

        (bool exists, bool settled, bool result) = adapter.getAssertionStatus(conditionId);
        assertTrue(exists);
        assertTrue(settled);
        assertTrue(result); // default mockOO settles truthfully
    }

    // ─── setBondAmount / setLiveness ─────────────────────────────────────────

    function test_setBondAmount() public {
        vm.prank(owner);
        adapter.setBondAmount(1000e6);
        assertEq(adapter.bondAmount(), 1000e6);
    }

    function test_setBondAmount_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setBondAmount(1000e6);
    }

    function test_setLiveness() public {
        vm.prank(owner);
        adapter.setLiveness(3600); // 1 hour
        assertEq(adapter.livenessSeconds(), 3600);
    }

    // ─── registerCondition ────────────────────────────────────────────────────

    function test_registerCondition() public {
        bytes32 newQId = keccak256("new question");
        bytes32 newConditionId = ct.getConditionId(address(adapter), newQId, 2);

        vm.prank(owner);
        adapter.registerCondition(newConditionId, newQId);

        assertEq(adapter.conditionQuestionIds(newConditionId), newQId);
    }

    function test_registerCondition_revert_notOwnerOrMarket() public {
        vm.prank(alice);
        vm.expectRevert(UMAOracleAdapter.OnlyPredictionMarket.selector);
        adapter.registerCondition(conditionId, questionId);
    }
}
