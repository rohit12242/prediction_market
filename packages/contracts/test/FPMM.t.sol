// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {IConditionalTokens} from "../src/interfaces/IConditionalTokens.sol";
import {FixedProductMarketMaker, FPMMFactory} from "../src/FPMMFactory.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

contract FPMMTest is Test {
    ConditionalTokens public ct;
    FPMMFactory public factory;
    FixedProductMarketMaker public fpmm;
    ERC20Mock public usdc;

    address public oracle = address(uint160(0xA11CE));
    address public alice = address(uint160(0xA1CE));
    address public bob = address(0xB0B);
    address public carol = address(uint160(0xCA401));

    bytes32 public questionId = keccak256("Will BTC reach $200k?");
    bytes32 public conditionId;
    uint256 public constant FEE_BPS = 200; // 2%
    uint256 public constant INITIAL_FUNDS = 1_000e6; // 1000 USDC

    uint256[] public partition;

    function setUp() public {
        ct = new ConditionalTokens();
        factory = new FPMMFactory();
        usdc = new ERC20Mock("USD Coin", "USDC", 6);

        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(carol, 100_000e6);

        // Prepare condition
        conditionId = ct.getConditionId(oracle, questionId, 2);
        ct.prepareCondition(oracle, questionId, 2);

        // Deploy FPMM
        fpmm = FixedProductMarketMaker(factory.createFPMM(IERC20(address(usdc)), IConditionalTokens(address(ct)), conditionId, FEE_BPS));

        partition = new uint256[](2);
        partition[0] = 1; // YES
        partition[1] = 2; // NO

        // Add initial funding from alice
        vm.startPrank(alice);
        usdc.approve(address(fpmm), INITIAL_FUNDS);
        fpmm.addFunding(INITIAL_FUNDS, new uint256[](0));
        vm.stopPrank();
    }

    // ─── addFunding ───────────────────────────────────────────────────────────

    function test_addFunding_initial() public view {
        // After initial funding: reserves should be [1000, 1000]
        uint256[] memory reserves = fpmm.getReserves();
        assertEq(reserves[0], INITIAL_FUNDS);
        assertEq(reserves[1], INITIAL_FUNDS);

        // LP shares should equal initial funds for equal distribution
        assertGt(IERC20(address(fpmm)).balanceOf(alice), 0);
    }

    function test_addFunding_subsequent() public {
        uint256 additionalFunds = 500e6;
        uint256 aliceSharesBefore = IERC20(address(fpmm)).balanceOf(alice);

        vm.startPrank(bob);
        usdc.approve(address(fpmm), additionalFunds);
        (uint256 mintedShares,) = fpmm.addFunding(additionalFunds, new uint256[](0));
        vm.stopPrank();

        assertGt(mintedShares, 0);
        uint256 bobShares = IERC20(address(fpmm)).balanceOf(bob);
        assertEq(bobShares, mintedShares);

        // Reserves should increase
        uint256[] memory reserves = fpmm.getReserves();
        assertGt(reserves[0], INITIAL_FUNDS);
    }

    function test_addFunding_withDistributionHint() public {
        // Add funding with hint that biases YES to 60%, NO to 40%
        uint256[] memory hint = new uint256[](2);
        hint[0] = 60; // YES
        hint[1] = 40; // NO

        uint256 funds = 1_000e6;
        vm.startPrank(bob);
        usdc.approve(address(fpmm), funds);
        (uint256 mintedShares, uint256[] memory sendBack) = fpmm.addFunding(funds, hint);
        vm.stopPrank();

        // Some tokens should be sent back (for non-uniform distribution)
        assertGt(mintedShares, 0);
        // sendBack might be non-zero for non-uniform initial funding
        // (only applies on first funding; this is second funding so hint ignored)
    }

    function test_addFunding_revert_zero() public {
        vm.startPrank(alice);
        usdc.approve(address(fpmm), 1);
        vm.expectRevert(FixedProductMarketMaker.ZeroAmount.selector);
        fpmm.addFunding(0, new uint256[](0));
        vm.stopPrank();
    }

    // ─── removeFunding ────────────────────────────────────────────────────────

    function test_removeFunding_basic() public {
        uint256 aliceShares = IERC20(address(fpmm)).balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        IERC20(address(fpmm)).approve(address(fpmm), aliceShares);
        fpmm.removeFunding(aliceShares);
        vm.stopPrank();

        assertEq(IERC20(address(fpmm)).balanceOf(alice), 0);
        assertGt(usdc.balanceOf(alice), aliceUsdcBefore); // received some USDC back
    }

    function test_removeFunding_partial() public {
        uint256 aliceShares = IERC20(address(fpmm)).balanceOf(alice);
        uint256 halfShares = aliceShares / 2;

        vm.startPrank(alice);
        IERC20(address(fpmm)).approve(address(fpmm), halfShares);
        fpmm.removeFunding(halfShares);
        vm.stopPrank();

        assertEq(IERC20(address(fpmm)).balanceOf(alice), aliceShares - halfShares);
    }

    function test_removeFunding_revert_zero() public {
        vm.startPrank(alice);
        vm.expectRevert(FixedProductMarketMaker.ZeroAmount.selector);
        fpmm.removeFunding(0);
        vm.stopPrank();
    }

    // ─── buy ──────────────────────────────────────────────────────────────────

    function test_buy_yes() public {
        uint256 investment = 100e6; // 100 USDC
        uint256 expectedTokens = fpmm.calcBuyAmount(investment, 0);
        assertGt(expectedTokens, 0);

        vm.startPrank(bob);
        usdc.approve(address(fpmm), investment);
        uint256 tokensBought = fpmm.buy(investment, 0, 0);
        vm.stopPrank();

        assertEq(tokensBought, expectedTokens);

        // Bob should hold YES tokens
        bytes32 yesCollection = ct.getCollectionId(bytes32(0), conditionId, 1);
        uint256 yesId = uint256(ct.getPositionId(IERC20(address(usdc)), yesCollection));
        assertEq(ct.balanceOf(bob, yesId), tokensBought);
    }

    function test_buy_no() public {
        uint256 investment = 100e6;
        uint256 expectedTokens = fpmm.calcBuyAmount(investment, 1);
        assertGt(expectedTokens, 0);

        vm.startPrank(bob);
        usdc.approve(address(fpmm), investment);
        uint256 tokensBought = fpmm.buy(investment, 1, 0);
        vm.stopPrank();

        assertEq(tokensBought, expectedTokens);

        bytes32 noCollection = ct.getCollectionId(bytes32(0), conditionId, 2);
        uint256 noId = uint256(ct.getPositionId(IERC20(address(usdc)), noCollection));
        assertEq(ct.balanceOf(bob, noId), tokensBought);
    }

    function test_buy_feeDeducted() public {
        // With 2% fee on 100 USDC: 98 USDC net investment
        // Token calc uses net amount
        uint256 investment = 100e6;
        uint256 grossTokens = fpmm.calcBuyAmount(investment, 0);

        // Check that fee is being deducted (net investment != gross)
        uint256 netInvestment = (investment * (10_000 - FEE_BPS)) / 10_000;
        uint256[] memory reserves = fpmm.getReserves();

        // Manual calc: outcomeTokensBought = r0 + netInv - k / (r1 + netInv)
        uint256 k = reserves[0] * reserves[1];
        uint256 expected = reserves[0] + netInvestment - k / (reserves[1] + netInvestment);
        assertEq(grossTokens, expected);
    }

    function test_buy_priceImpact() public {
        // Larger buy should have worse price
        uint256 smallTokens = fpmm.calcBuyAmount(10e6, 0);
        uint256 largeTokens = fpmm.calcBuyAmount(100e6, 0);

        // 10x investment should yield less than 10x tokens (price impact)
        assertLt(largeTokens, smallTokens * 10);
    }

    function test_buy_revert_slippage() public {
        uint256 investment = 100e6;
        uint256 expectedTokens = fpmm.calcBuyAmount(investment, 0);

        vm.startPrank(bob);
        usdc.approve(address(fpmm), investment);
        vm.expectRevert(FixedProductMarketMaker.SlippageExceeded.selector);
        fpmm.buy(investment, 0, expectedTokens + 1); // too high min
        vm.stopPrank();
    }

    function test_buy_revert_zeroAmount() public {
        vm.startPrank(bob);
        usdc.approve(address(fpmm), 1);
        vm.expectRevert(FixedProductMarketMaker.ZeroAmount.selector);
        fpmm.buy(0, 0, 0);
        vm.stopPrank();
    }

    function test_buy_revert_invalidOutcome() public {
        vm.startPrank(bob);
        usdc.approve(address(fpmm), 100e6);
        vm.expectRevert(FixedProductMarketMaker.InvalidOutcomeIndex.selector);
        fpmm.buy(100e6, 5, 0); // invalid outcome
        vm.stopPrank();
    }

    // ─── sell ─────────────────────────────────────────────────────────────────

    function test_sell_yes() public {
        // First buy some YES tokens
        uint256 investment = 100e6;
        vm.startPrank(bob);
        usdc.approve(address(fpmm), investment);
        uint256 tokensBought = fpmm.buy(investment, 0, 0);
        vm.stopPrank();

        // Now sell half back
        uint256 returnAmount = 40e6; // want 40 USDC back
        uint256 tokensNeeded = fpmm.calcSellAmount(returnAmount, 0);
        assertGt(tokensNeeded, 0);
        assertLt(tokensNeeded, tokensBought);

        bytes32 yesCollection = ct.getCollectionId(bytes32(0), conditionId, 1);
        uint256 yesId = uint256(ct.getPositionId(IERC20(address(usdc)), yesCollection));

        uint256 usdcBefore = usdc.balanceOf(bob);

        vm.startPrank(bob);
        ct.setApprovalForAll(address(fpmm), true);
        fpmm.sell(returnAmount, 0, tokensNeeded + 1e18); // give generous slippage
        vm.stopPrank();

        assertEq(usdc.balanceOf(bob), usdcBefore + returnAmount);
        assertEq(ct.balanceOf(bob, yesId), tokensBought - tokensNeeded);
    }

    function test_sell_revert_slippage() public {
        uint256 investment = 100e6;
        vm.startPrank(bob);
        usdc.approve(address(fpmm), investment);
        fpmm.buy(investment, 0, 0);

        uint256 returnAmount = 40e6;
        uint256 tokensNeeded = fpmm.calcSellAmount(returnAmount, 0);

        ct.setApprovalForAll(address(fpmm), true);
        vm.expectRevert(FixedProductMarketMaker.SlippageExceeded.selector);
        fpmm.sell(returnAmount, 0, tokensNeeded - 1); // too tight slippage
        vm.stopPrank();
    }

    // ─── calcBuyAmount / calcSellAmount ───────────────────────────────────────

    function test_calcBuyAmount_symmetry() public view {
        uint256[] memory reserves = fpmm.getReserves();

        // For equal reserves, YES and NO should have same price
        uint256 yesTokens = fpmm.calcBuyAmount(100e6, 0);
        uint256 noTokens = fpmm.calcBuyAmount(100e6, 1);
        assertEq(yesTokens, noTokens);
    }

    function test_invariant_maintained_after_buy() public {
        uint256[] memory reservesBefore = fpmm.getReserves();
        uint256 kBefore = reservesBefore[0] * reservesBefore[1];

        vm.startPrank(bob);
        usdc.approve(address(fpmm), 100e6);
        fpmm.buy(100e6, 0, 0);
        vm.stopPrank();

        uint256[] memory reservesAfter = fpmm.getReserves();
        uint256 kAfter = reservesAfter[0] * reservesAfter[1];

        // Product should increase or stay same (fee goes to pool, k may dip slightly due to integer division)
        assertGe(kAfter + 1e12, kBefore); // allow tiny rounding slack
    }

    function test_spotPrice_initial() public view {
        // At equal reserves, both outcomes should be 50%
        uint256 yesPrice = fpmm.getSpotPrice(0);
        uint256 noPrice = fpmm.getSpotPrice(1);

        // Each should be 0.5e18 = 50%
        assertEq(yesPrice, 0.5e18);
        assertEq(noPrice, 0.5e18);
    }

    function test_feePool_accumulates() public {
        uint256 feeBefore = fpmm.feePool();

        vm.startPrank(bob);
        usdc.approve(address(fpmm), 100e6);
        fpmm.buy(100e6, 0, 0);
        vm.stopPrank();

        assertGt(fpmm.feePool(), feeBefore);
    }
}
