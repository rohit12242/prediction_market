// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ConditionalTokensTest is Test {
    ConditionalTokens public ct;
    ERC20Mock public usdc;

    address public oracle = address(uint160(0xA11CE));
    address public alice = address(uint160(0xA1CE));
    address public bob = address(0xB0B);

    bytes32 public questionId = keccak256("Will ETH reach $10k by end of 2025?");
    uint256 public constant OUTCOME_COUNT = 2;
    uint256 public constant AMOUNT = 1000e6; // 1000 USDC

    bytes32 public conditionId;
    uint256[] public partition;

    function setUp() public {
        ct = new ConditionalTokens();
        usdc = new ERC20Mock("USD Coin", "USDC", 6);

        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);

        conditionId = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);

        partition = new uint256[](2);
        partition[0] = 1; // YES (bit 0)
        partition[1] = 2; // NO (bit 1)
    }

    // ─── prepareCondition ─────────────────────────────────────────────────────

    function test_prepareCondition_basic() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);

        assertEq(ct.getOutcomeSlotCount(conditionId), OUTCOME_COUNT);
        assertTrue(ct.isConditionPrepared(conditionId));
        assertFalse(ct.isConditionResolved(conditionId));
    }

    function test_prepareCondition_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ConditionalTokens.ConditionPrepared(conditionId, oracle, questionId, OUTCOME_COUNT);
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
    }

    function test_prepareCondition_revert_doublePrepare() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
        vm.expectRevert(ConditionalTokens.ConditionAlreadyPrepared.selector);
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
    }

    function test_prepareCondition_revert_invalidSlotCount() public {
        vm.expectRevert(ConditionalTokens.InvalidOutcomeSlotCount.selector);
        ct.prepareCondition(oracle, questionId, 1); // must be >= 2

        vm.expectRevert(ConditionalTokens.InvalidOutcomeSlotCount.selector);
        ct.prepareCondition(oracle, questionId, 0);
    }

    function test_prepareCondition_manyOutcomes() public {
        ct.prepareCondition(oracle, questionId, 4);
        bytes32 cid = ct.getConditionId(oracle, questionId, 4);
        assertEq(ct.getOutcomeSlotCount(cid), 4);
    }

    // ─── getConditionId ───────────────────────────────────────────────────────

    function test_getConditionId_deterministic() public view {
        bytes32 cid1 = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);
        bytes32 cid2 = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);
        assertEq(cid1, cid2);
    }

    function test_getConditionId_differentOracles() public view {
        bytes32 cid1 = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);
        bytes32 cid2 = ct.getConditionId(address(0xDEAD), questionId, OUTCOME_COUNT);
        assertTrue(cid1 != cid2);
    }

    // ─── splitPosition ────────────────────────────────────────────────────────

    function test_splitPosition_basic() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);

        vm.startPrank(alice);
        usdc.approve(address(ct), AMOUNT);
        ct.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, AMOUNT);
        vm.stopPrank();

        // Alice should have YES and NO tokens
        bytes32 yesCollection = ct.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollection = ct.getCollectionId(bytes32(0), conditionId, 2);
        uint256 yesId = uint256(ct.getPositionId(IERC20(address(usdc)), yesCollection));
        uint256 noId = uint256(ct.getPositionId(IERC20(address(usdc)), noCollection));

        assertEq(ct.balanceOf(alice, yesId), AMOUNT);
        assertEq(ct.balanceOf(alice, noId), AMOUNT);

        // CT should hold the USDC
        assertEq(usdc.balanceOf(address(ct)), AMOUNT);
        assertEq(usdc.balanceOf(alice), 10_000e6 - AMOUNT);
    }

    function test_splitPosition_totalSupplyTracked() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);

        vm.startPrank(alice);
        usdc.approve(address(ct), AMOUNT);
        ct.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, AMOUNT);
        vm.stopPrank();

        bytes32 yesCollection = ct.getCollectionId(bytes32(0), conditionId, 1);
        uint256 yesId = uint256(ct.getPositionId(IERC20(address(usdc)), yesCollection));
        assertEq(ct.totalSupply(yesId), AMOUNT);
    }

    function test_splitPosition_revert_conditionNotPrepared() public {
        vm.startPrank(alice);
        usdc.approve(address(ct), AMOUNT);
        vm.expectRevert(ConditionalTokens.ConditionNotPrepared.selector);
        ct.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, AMOUNT);
        vm.stopPrank();
    }

    function test_splitPosition_revert_zeroAmount() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
        vm.startPrank(alice);
        usdc.approve(address(ct), AMOUNT);
        vm.expectRevert(ConditionalTokens.ZeroAmount.selector);
        ct.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, 0);
        vm.stopPrank();
    }

    function test_splitPosition_revert_invalidPartition_overlapping() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory badPartition = new uint256[](2);
        badPartition[0] = 1;
        badPartition[1] = 1; // same index set = overlapping

        vm.startPrank(alice);
        usdc.approve(address(ct), AMOUNT);
        vm.expectRevert(ConditionalTokens.InvalidPartition.selector);
        ct.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, badPartition, AMOUNT);
        vm.stopPrank();
    }

    function test_splitPosition_revert_singlePartition() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory singlePartition = new uint256[](1);
        singlePartition[0] = 1;

        vm.startPrank(alice);
        usdc.approve(address(ct), AMOUNT);
        vm.expectRevert(ConditionalTokens.EmptyPartition.selector);
        ct.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, singlePartition, AMOUNT);
        vm.stopPrank();
    }

    // ─── mergePositions ───────────────────────────────────────────────────────

    function test_mergePositions_basic() public {
        _splitAlice(AMOUNT);

        bytes32 yesCollection = ct.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollection = ct.getCollectionId(bytes32(0), conditionId, 2);
        uint256 yesId = uint256(ct.getPositionId(IERC20(address(usdc)), yesCollection));
        uint256 noId = uint256(ct.getPositionId(IERC20(address(usdc)), noCollection));

        vm.startPrank(alice);
        ct.setApprovalForAll(address(ct), true);
        ct.mergePositions(IERC20(address(usdc)), bytes32(0), conditionId, partition, AMOUNT);
        vm.stopPrank();

        assertEq(ct.balanceOf(alice, yesId), 0);
        assertEq(ct.balanceOf(alice, noId), 0);
        assertEq(usdc.balanceOf(alice), 10_000e6); // full refund
    }

    function test_mergePositions_partial() public {
        _splitAlice(AMOUNT);

        vm.startPrank(alice);
        ct.setApprovalForAll(address(ct), true);
        ct.mergePositions(IERC20(address(usdc)), bytes32(0), conditionId, partition, AMOUNT / 2);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 10_000e6 - AMOUNT / 2);
    }

    // ─── reportPayouts ────────────────────────────────────────────────────────

    function test_reportPayouts_yesWins() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1; // YES wins
        payouts[1] = 0;

        vm.prank(oracle);
        ct.reportPayouts(questionId, payouts);

        assertEq(ct.payoutDenominator(conditionId), 1);
        assertEq(ct.payoutNumerators(conditionId, 0), 1);
        assertEq(ct.payoutNumerators(conditionId, 1), 0);
        assertTrue(ct.isConditionResolved(conditionId));
    }

    function test_reportPayouts_noWins() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 0;
        payouts[1] = 1; // NO wins

        vm.prank(oracle);
        ct.reportPayouts(questionId, payouts);

        assertEq(ct.payoutNumerators(conditionId, 1), 1);
    }

    function test_reportPayouts_invalidOutcome_split() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 1; // both get some payout

        vm.prank(oracle);
        ct.reportPayouts(questionId, payouts);

        assertEq(ct.payoutDenominator(conditionId), 2);
    }

    function test_reportPayouts_revert_notOracle() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.prank(alice); // not oracle
        vm.expectRevert(ConditionalTokens.ConditionNotPrepared.selector);
        ct.reportPayouts(questionId, payouts);
    }

    function test_reportPayouts_revert_doubleReport() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;

        vm.prank(oracle);
        ct.reportPayouts(questionId, payouts);

        vm.prank(oracle);
        vm.expectRevert(ConditionalTokens.ConditionAlreadyResolved.selector);
        ct.reportPayouts(questionId, payouts);
    }

    function test_reportPayouts_revert_allZero() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 0;
        payouts[1] = 0;

        vm.prank(oracle);
        vm.expectRevert(ConditionalTokens.PayoutZero.selector);
        ct.reportPayouts(questionId, payouts);
    }

    // ─── redeemPositions ──────────────────────────────────────────────────────

    function test_redeemPositions_yesWins() public {
        _splitAlice(AMOUNT);

        // YES wins
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;
        vm.prank(oracle);
        ct.reportPayouts(questionId, payouts);

        bytes32 yesCollection = ct.getCollectionId(bytes32(0), conditionId, 1);
        uint256 yesId = uint256(ct.getPositionId(IERC20(address(usdc)), yesCollection));

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 1; // redeem YES

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        ct.setApprovalForAll(address(ct), true);
        ct.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId, indexSets);
        vm.stopPrank();

        // Alice should receive full USDC back (YES tokens = full payout)
        assertEq(usdc.balanceOf(alice), balanceBefore + AMOUNT);
        assertEq(ct.balanceOf(alice, yesId), 0); // YES tokens burned
    }

    function test_redeemPositions_noWins() public {
        _splitAlice(AMOUNT);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 0;
        payouts[1] = 1; // NO wins
        vm.prank(oracle);
        ct.reportPayouts(questionId, payouts);

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 2; // redeem NO

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        ct.setApprovalForAll(address(ct), true);
        ct.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId, indexSets);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), balanceBefore + AMOUNT);
    }

    function test_redeemPositions_revert_notResolved() public {
        _splitAlice(AMOUNT);

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 1;

        vm.startPrank(alice);
        ct.setApprovalForAll(address(ct), true);
        vm.expectRevert(ConditionalTokens.ConditionNotResolved.selector);
        ct.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId, indexSets);
        vm.stopPrank();
    }

    function test_redeemPositions_zeroBalanceNoOp() public {
        _splitAlice(AMOUNT);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        vm.prank(oracle);
        ct.reportPayouts(questionId, payouts);

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 1;

        // Bob has no tokens but tries to redeem (should emit 0 payout, not revert)
        uint256 balanceBefore = usdc.balanceOf(bob);
        vm.startPrank(bob);
        ct.setApprovalForAll(address(ct), true);
        ct.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId, indexSets);
        vm.stopPrank();

        assertEq(usdc.balanceOf(bob), balanceBefore); // no change
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _splitAlice(uint256 amount) internal {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
        vm.startPrank(alice);
        usdc.approve(address(ct), amount);
        ct.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, amount);
        vm.stopPrank();
    }
}
