// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {CLOBOrderBook} from "../src/CLOBOrderBook.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {IConditionalTokens} from "../src/interfaces/IConditionalTokens.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CLOBOrderBookTest is Test {
    ConditionalTokens public ct;
    CLOBOrderBook public clob;
    ERC20Mock public usdc;

    address public owner = address(uint160(0xABCD));
    address public feeRecipient = address(uint160(0xFEE5));
    address public oracle = address(uint160(0xA11CE));
    address public alice = address(uint160(0xA1CE));
    address public bob = address(uint160(0xB0B5));
    address public carol = address(uint160(0xCA401));

    bytes32 public questionId = keccak256("CLOB test market?");
    bytes32 public conditionId;

    uint256 public constant MAKER_FEE = 10; // 0.1%
    uint256 public constant TAKER_FEE = 20; // 0.2%

    // YES tokens position ID
    uint256 public yesPositionId;
    uint256 public noPositionId;

    uint256[] public partition;

    function setUp() public {
        ct = new ConditionalTokens();
        usdc = new ERC20Mock("USD Coin", "USDC", 6);

        // Prepare condition
        conditionId = ct.getConditionId(oracle, questionId, 2);
        ct.prepareCondition(oracle, questionId, 2);

        // Deploy CLOB
        clob = new CLOBOrderBook(
            IERC20(address(usdc)),
            IConditionalTokens(address(ct)),
            conditionId,
            MAKER_FEE,
            TAKER_FEE,
            feeRecipient,
            owner
        );

        // Mint USDC
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(carol, 1_000_000e6);

        // Get position IDs
        bytes32 yesCollection = ct.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollection = ct.getCollectionId(bytes32(0), conditionId, 2);
        yesPositionId = uint256(ct.getPositionId(IERC20(address(usdc)), yesCollection));
        noPositionId = uint256(ct.getPositionId(IERC20(address(usdc)), noCollection));

        partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        // Give alice and bob outcome tokens
        _mintOutcomeTokens(alice, 100_000e6);
        _mintOutcomeTokens(bob, 100_000e6);
        _mintOutcomeTokens(carol, 100_000e6);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Compute USDC commitment for a BUY limit order (fee-inclusive).
    function _buyCommit(uint256 price, uint256 amount) internal pure returns (uint256) {
        uint256 base = (price * amount) / 1e6;
        return (base * (10_000 + TAKER_FEE)) / 10_000;
    }

    // ─── placeLimitOrder ──────────────────────────────────────────────────────

    function test_placeLimitOrder_buyYes() public {
        uint256 price = 500_000; // 0.5 USDC per token
        uint256 amount = 10e6; // 10 outcome tokens

        uint256 usdcExpected = _buyCommit(price, amount);

        vm.startPrank(alice);
        usdc.approve(address(clob), usdcExpected);
        bytes32 orderId = clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, price, amount);
        vm.stopPrank();

        CLOBOrderBook.Order memory order = clob.getOrder(orderId);
        assertEq(order.trader, alice);
        assertEq(uint8(order.side), uint8(CLOBOrderBook.Side.BUY));
        assertEq(order.price, price);
        assertEq(order.originalAmount, amount);
        assertEq(order.remainingAmount, amount);
        assertEq(order.usdcCommitted, usdcExpected);
        assertEq(uint8(order.status), uint8(CLOBOrderBook.OrderStatus.Open));
    }

    function test_placeLimitOrder_sellYes() public {
        uint256 price = 600_000; // 0.6 USDC per token
        uint256 amount = 5e6;

        vm.startPrank(alice);
        ct.setApprovalForAll(address(clob), true);
        bytes32 orderId = clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, price, amount);
        vm.stopPrank();

        CLOBOrderBook.Order memory order = clob.getOrder(orderId);
        assertEq(order.trader, alice);
        assertEq(uint8(order.side), uint8(CLOBOrderBook.Side.SELL));
        assertEq(order.price, price);
        assertEq(order.originalAmount, amount);

        // CLOB should now hold alice's tokens
        assertEq(ct.balanceOf(address(clob), yesPositionId), amount);
    }

    function test_placeLimitOrder_emitsOrderPlaced() public {
        uint256 price = 500_000;
        uint256 amount = 10e6;
        uint256 usdcNeeded = _buyCommit(price, amount);

        vm.startPrank(alice);
        usdc.approve(address(clob), usdcNeeded);

        vm.expectEmit(false, true, false, true);
        emit CLOBOrderBook.OrderPlaced(bytes32(0), alice, CLOBOrderBook.Side.BUY, 0, price, amount);
        clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, price, amount);
        vm.stopPrank();
    }

    function test_placeLimitOrder_revert_invalidPrice_zero() public {
        vm.startPrank(alice);
        usdc.approve(address(clob), 1000e6);
        vm.expectRevert(CLOBOrderBook.InvalidPrice.selector);
        clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, 0, 10e6);
        vm.stopPrank();
    }

    function test_placeLimitOrder_revert_invalidPrice_max() public {
        vm.startPrank(alice);
        usdc.approve(address(clob), 1000e6);
        vm.expectRevert(CLOBOrderBook.InvalidPrice.selector);
        clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, 1_000_000, 10e6); // >= 1 USDC
        vm.stopPrank();
    }

    function test_placeLimitOrder_revert_invalidOutcome() public {
        vm.startPrank(alice);
        usdc.approve(address(clob), 1000e6);
        vm.expectRevert(CLOBOrderBook.InvalidOutcomeIndex.selector);
        clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 5, 500_000, 10e6);
        vm.stopPrank();
    }

    function test_placeLimitOrder_revert_zeroAmount() public {
        vm.startPrank(alice);
        usdc.approve(address(clob), 1000e6);
        vm.expectRevert(CLOBOrderBook.InvalidAmount.selector);
        clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, 500_000, 0);
        vm.stopPrank();
    }

    function test_placeLimitOrder_revert_insufficientBalance_sell() public {
        uint256 amount = 200_000e6; // more than alice has (she has 100_000e6)

        vm.startPrank(alice);
        ct.setApprovalForAll(address(clob), true);
        vm.expectRevert(CLOBOrderBook.InsufficientBalance.selector);
        clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, 600_000, amount);
        vm.stopPrank();
    }

    // ─── Order Matching ───────────────────────────────────────────────────────

    function test_matchOrders_fullFill() public {
        uint256 price = 500_000;
        uint256 amount = 10e6;

        // Alice places sell order
        vm.startPrank(alice);
        ct.setApprovalForAll(address(clob), true);
        bytes32 sellOrderId = clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, price, amount);
        vm.stopPrank();

        // Bob places matching buy order
        uint256 usdcNeeded = _buyCommit(price, amount);
        vm.startPrank(bob);
        usdc.approve(address(clob), usdcNeeded);
        bytes32 buyOrderId = clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, price, amount);
        vm.stopPrank();

        // Both orders should be filled
        CLOBOrderBook.Order memory sellOrder = clob.getOrder(sellOrderId);
        CLOBOrderBook.Order memory buyOrder = clob.getOrder(buyOrderId);

        assertEq(uint8(sellOrder.status), uint8(CLOBOrderBook.OrderStatus.Filled));
        assertEq(uint8(buyOrder.status), uint8(CLOBOrderBook.OrderStatus.Filled));

        // Bob should have YES tokens (original 100_000e6 + amount bought)
        assertEq(ct.balanceOf(bob, yesPositionId), 100_000e6 + amount); // original + bought
    }

    function test_matchOrders_partialFill() public {
        uint256 price = 500_000;
        uint256 sellAmount = 20e6;
        uint256 buyAmount = 5e6; // partial

        // Alice places large sell order
        vm.startPrank(alice);
        ct.setApprovalForAll(address(clob), true);
        bytes32 sellOrderId = clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, price, sellAmount);
        vm.stopPrank();

        // Bob places smaller buy order
        uint256 usdcNeeded = _buyCommit(price, buyAmount);
        vm.startPrank(bob);
        usdc.approve(address(clob), usdcNeeded);
        bytes32 buyOrderId = clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, price, buyAmount);
        vm.stopPrank();

        // Buy should be filled, sell should be partial
        CLOBOrderBook.Order memory sellOrder = clob.getOrder(sellOrderId);
        CLOBOrderBook.Order memory buyOrder = clob.getOrder(buyOrderId);

        assertEq(uint8(buyOrder.status), uint8(CLOBOrderBook.OrderStatus.Filled));
        assertEq(uint8(sellOrder.status), uint8(CLOBOrderBook.OrderStatus.PartiallyFilled));
        assertEq(sellOrder.remainingAmount, sellAmount - buyAmount);
    }

    function test_matchOrders_noMatch_spreadNotCrossed() public {
        uint256 bidPrice = 450_000;
        uint256 askPrice = 550_000; // bid < ask, no match

        uint256 usdcNeeded = _buyCommit(bidPrice, 10e6);

        vm.startPrank(alice);
        usdc.approve(address(clob), usdcNeeded);
        bytes32 buyOrderId = clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, bidPrice, 10e6);
        vm.stopPrank();

        vm.startPrank(bob);
        ct.setApprovalForAll(address(clob), true);
        bytes32 sellOrderId = clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, askPrice, 10e6);
        vm.stopPrank();

        // Neither should be matched
        assertEq(uint8(clob.getOrder(buyOrderId).status), uint8(CLOBOrderBook.OrderStatus.Open));
        assertEq(uint8(clob.getOrder(sellOrderId).status), uint8(CLOBOrderBook.OrderStatus.Open));
    }

    function test_matchOrders_multipleFills() public {
        uint256 price = 500_000;

        // Alice places 3 small sell orders
        vm.startPrank(alice);
        ct.setApprovalForAll(address(clob), true);
        bytes32 sell1 = clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, price, 3e6);
        bytes32 sell2 = clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, price, 3e6);
        bytes32 sell3 = clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, price, 3e6);
        vm.stopPrank();

        // Bob places large buy order that covers all
        uint256 totalAmount = 9e6;
        uint256 usdcNeeded = _buyCommit(price, totalAmount);
        vm.startPrank(bob);
        usdc.approve(address(clob), usdcNeeded);
        bytes32 bigBuy = clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, price, totalAmount);
        vm.stopPrank();

        // All orders should be filled
        assertEq(uint8(clob.getOrder(sell1).status), uint8(CLOBOrderBook.OrderStatus.Filled));
        assertEq(uint8(clob.getOrder(sell2).status), uint8(CLOBOrderBook.OrderStatus.Filled));
        assertEq(uint8(clob.getOrder(sell3).status), uint8(CLOBOrderBook.OrderStatus.Filled));
        assertEq(uint8(clob.getOrder(bigBuy).status), uint8(CLOBOrderBook.OrderStatus.Filled));
    }

    function test_matchOrders_pricePriorityBestAsk() public {
        // Two sell orders at different prices; buyer should match with cheaper ask first
        vm.startPrank(alice);
        ct.setApprovalForAll(address(clob), true);
        bytes32 expensiveSell = clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, 600_000, 5e6);
        bytes32 cheapSell = clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, 400_000, 5e6);
        vm.stopPrank();

        uint256 usdcNeeded = _buyCommit(600_000, 5e6); // enough for either
        vm.startPrank(bob);
        usdc.approve(address(clob), usdcNeeded);
        bytes32 buyOrder = clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, 600_000, 5e6);
        vm.stopPrank();

        // Should match with cheap sell first (best ask)
        assertEq(uint8(clob.getOrder(cheapSell).status), uint8(CLOBOrderBook.OrderStatus.Filled));
        assertEq(uint8(clob.getOrder(buyOrder).status), uint8(CLOBOrderBook.OrderStatus.Filled));
        // Expensive sell still open
        assertEq(uint8(clob.getOrder(expensiveSell).status), uint8(CLOBOrderBook.OrderStatus.Open));
    }

    // ─── cancelOrder ──────────────────────────────────────────────────────────

    function test_cancelOrder_buy() public {
        uint256 price = 500_000;
        uint256 amount = 10e6;
        uint256 usdcNeeded = _buyCommit(price, amount);

        vm.startPrank(alice);
        usdc.approve(address(clob), usdcNeeded);
        bytes32 orderId = clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, price, amount);

        uint256 usdcBefore = usdc.balanceOf(alice);
        clob.cancelOrder(orderId);
        vm.stopPrank();

        // USDC refunded
        assertEq(usdc.balanceOf(alice), usdcBefore + usdcNeeded);
        assertEq(uint8(clob.getOrder(orderId).status), uint8(CLOBOrderBook.OrderStatus.Cancelled));
    }

    function test_cancelOrder_sell() public {
        uint256 price = 600_000;
        uint256 amount = 5e6;

        vm.startPrank(alice);
        ct.setApprovalForAll(address(clob), true);
        bytes32 orderId = clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, price, amount);

        uint256 tokensBefore = ct.balanceOf(alice, yesPositionId);
        clob.cancelOrder(orderId);
        vm.stopPrank();

        // Tokens refunded
        assertEq(ct.balanceOf(alice, yesPositionId), tokensBefore + amount);
        assertEq(uint8(clob.getOrder(orderId).status), uint8(CLOBOrderBook.OrderStatus.Cancelled));
    }

    function test_cancelOrder_revert_notOwner() public {
        uint256 usdcNeeded = _buyCommit(500_000, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(clob), usdcNeeded);
        bytes32 orderId = clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, 500_000, 10e6);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(CLOBOrderBook.NotOrderOwner.selector);
        clob.cancelOrder(orderId);
    }

    function test_cancelOrder_revert_alreadyCancelled() public {
        uint256 usdcNeeded = _buyCommit(500_000, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(clob), usdcNeeded);
        bytes32 orderId = clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, 500_000, 10e6);
        clob.cancelOrder(orderId);

        vm.expectRevert(CLOBOrderBook.OrderNotCancellable.selector);
        clob.cancelOrder(orderId);
        vm.stopPrank();
    }

    function test_cancelOrder_revert_orderNotFound() public {
        vm.prank(alice);
        vm.expectRevert(CLOBOrderBook.OrderNotFound.selector);
        clob.cancelOrder(bytes32(uint256(999)));
    }

    function test_cancelOrder_emitsEvent() public {
        uint256 usdcNeeded = _buyCommit(500_000, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(clob), usdcNeeded);
        bytes32 orderId = clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, 500_000, 10e6);

        vm.expectEmit(true, true, false, false);
        emit CLOBOrderBook.OrderCancelled(orderId, alice, 0);
        clob.cancelOrder(orderId);
        vm.stopPrank();
    }

    // ─── placeMarketOrder ─────────────────────────────────────────────────────

    function test_placeMarketOrder_buy() public {
        // Seed the order book with sell orders
        vm.startPrank(alice);
        ct.setApprovalForAll(address(clob), true);
        clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, 500_000, 20e6);
        vm.stopPrank();

        // Bob does market buy
        uint256 buyAmount = 10e6;
        uint256 maxUsdcNeeded = _buyCommit(600_000, buyAmount); // generous max price, fee-inclusive
        vm.startPrank(bob);
        usdc.approve(address(clob), maxUsdcNeeded);
        uint256 filled = clob.placeMarketOrder(CLOBOrderBook.Side.BUY, 0, buyAmount, 600_000);
        vm.stopPrank();

        assertEq(filled, buyAmount);
    }

    function test_placeMarketOrder_sell() public {
        // Seed the order book with buy orders
        uint256 usdcNeeded = _buyCommit(500_000, 20e6);
        vm.startPrank(alice);
        usdc.approve(address(clob), usdcNeeded);
        clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, 500_000, 20e6);
        vm.stopPrank();

        // Bob does market sell
        uint256 sellAmount = 10e6;
        vm.startPrank(bob);
        ct.setApprovalForAll(address(clob), true);
        uint256 filled = clob.placeMarketOrder(CLOBOrderBook.Side.SELL, 0, sellAmount, 400_000);
        vm.stopPrank();

        assertEq(filled, sellAmount);
    }

    function test_placeMarketOrder_revert_zero() public {
        vm.startPrank(alice);
        usdc.approve(address(clob), 1000e6);
        vm.expectRevert(CLOBOrderBook.InvalidAmount.selector);
        clob.placeMarketOrder(CLOBOrderBook.Side.BUY, 0, 0, 600_000);
        vm.stopPrank();
    }

    // ─── adminCancelAll ───────────────────────────────────────────────────────

    function test_adminCancelAll() public {
        // Place multiple orders
        uint256 usdcNeeded1 = _buyCommit(400_000, 10e6);
        uint256 usdcNeeded2 = _buyCommit(500_000, 10e6);

        vm.startPrank(alice);
        usdc.approve(address(clob), usdcNeeded1 + usdcNeeded2);
        bytes32 b1 = clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, 400_000, 10e6);
        bytes32 b2 = clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, 500_000, 10e6);
        vm.stopPrank();

        vm.startPrank(bob);
        ct.setApprovalForAll(address(clob), true);
        bytes32 s1 = clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, 600_000, 10e6);
        vm.stopPrank();

        // Admin cancel all
        vm.prank(owner);
        clob.adminCancelAll(0);

        assertEq(uint8(clob.getOrder(b1).status), uint8(CLOBOrderBook.OrderStatus.Cancelled));
        assertEq(uint8(clob.getOrder(b2).status), uint8(CLOBOrderBook.OrderStatus.Cancelled));
        assertEq(uint8(clob.getOrder(s1).status), uint8(CLOBOrderBook.OrderStatus.Cancelled));
    }

    function test_adminCancelAll_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        clob.adminCancelAll(0);
    }

    // ─── Fee accounting ───────────────────────────────────────────────────────

    function test_feeAccounting_onTrade() public {
        uint256 price = 500_000;
        uint256 amount = 100e6;

        // Alice sells, Bob buys → trade executes
        vm.startPrank(alice);
        ct.setApprovalForAll(address(clob), true);
        clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, price, amount);
        vm.stopPrank();

        uint256 usdcNeeded = _buyCommit(price, amount);
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);

        vm.startPrank(bob);
        usdc.approve(address(clob), usdcNeeded);
        clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, price, amount);
        vm.stopPrank();

        // Fee recipient should have received fees (makerFee on seller, takerFee on buyer)
        uint256 usdcAmount = (price * amount) / 1e6;
        uint256 expectedFees = (usdcAmount * (MAKER_FEE + TAKER_FEE)) / 10_000;
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBefore + expectedFees);
    }

    // ─── View functions ───────────────────────────────────────────────────────

    function test_getBestBid() public {
        uint256 price1 = 400_000;
        uint256 price2 = 500_000; // higher bid

        uint256 usdc1 = _buyCommit(price1, 5e6);
        uint256 usdc2 = _buyCommit(price2, 5e6);

        vm.startPrank(alice);
        usdc.approve(address(clob), usdc1 + usdc2);
        clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, price1, 5e6);
        clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, price2, 5e6);
        vm.stopPrank();

        (uint256 bestPrice,) = clob.getBestBid(0);
        assertEq(bestPrice, price2); // highest bid
    }

    function test_getBestAsk() public {
        uint256 price1 = 600_000;
        uint256 price2 = 500_000; // lower ask

        vm.startPrank(alice);
        ct.setApprovalForAll(address(clob), true);
        clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, price1, 5e6);
        clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, price2, 5e6);
        vm.stopPrank();

        (uint256 bestPrice,) = clob.getBestAsk(0);
        assertEq(bestPrice, price2); // lowest ask
    }

    function test_getOrderBook() public {
        // Place some orders
        uint256 bidUsdc = _buyCommit(500_000, 5e6);
        vm.startPrank(alice);
        usdc.approve(address(clob), bidUsdc);
        clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, 500_000, 5e6);
        vm.stopPrank();

        vm.startPrank(bob);
        ct.setApprovalForAll(address(clob), true);
        clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, 600_000, 5e6);
        vm.stopPrank();

        (uint256[] memory bidPrices, uint256[] memory bidAmts, uint256[] memory askPrices, uint256[] memory askAmts) =
            clob.getOrderBook(0, 5);

        assertEq(bidPrices[0], 500_000);
        assertGt(bidAmts[0], 0);
        assertEq(askPrices[0], 600_000);
        assertGt(askAmts[0], 0);
    }

    function test_getUserOrders() public {
        uint256 usdcNeeded = _buyCommit(500_000, 5e6);

        vm.startPrank(alice);
        usdc.approve(address(clob), usdcNeeded * 3);
        clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, 500_000, 5e6);
        clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, 400_000, 5e6);
        clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 1, 500_000, 5e6);
        vm.stopPrank();

        bytes32[] memory aliceOrders = clob.getUserOrders(alice);
        assertEq(aliceOrders.length, 3);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _mintOutcomeTokens(address to, uint256 amount) internal {
        // amount is in USDC (6 decimals). Each USDC unit of collateral yields 1 YES + 1 NO outcome token.
        // Split `amount` USDC into YES and NO tokens.
        usdc.mint(to, amount);
        vm.startPrank(to);
        usdc.approve(address(ct), amount);
        ct.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, amount);
        vm.stopPrank();
    }
}
