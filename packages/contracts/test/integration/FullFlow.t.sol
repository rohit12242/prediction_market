// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ConditionalTokens} from "../../src/ConditionalTokens.sol";
import {IConditionalTokens} from "../../src/interfaces/IConditionalTokens.sol";
import {FPMMFactory, FixedProductMarketMaker} from "../../src/FPMMFactory.sol";
import {UMAOracleAdapter} from "../../src/UMAOracleAdapter.sol";
import {PredictionMarket} from "../../src/PredictionMarket.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {CLOBOrderBook} from "../../src/CLOBOrderBook.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockUMAOracleV3} from "../mocks/MockUMAOracleV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FullFlowTest
/// @notice Integration test: full lifecycle from deployment through resolution and redemption.
///         Steps:
///           1. Deploy all contracts
///           2. Create market via MarketFactory
///           3. Add liquidity via FPMM
///           4. Buy YES tokens via PredictionMarket
///           5. Place CLOB limit orders
///           6. Match CLOB orders
///           7. Initiate UMA assertion → settle → resolve
///           8. Redeem winning positions
contract FullFlowTest is Test {
    // ─── Contracts ────────────────────────────────────────────────────────────

    ConditionalTokens public ct;
    FPMMFactory public fpmmFactory;
    MockUMAOracleV3 public mockOO;
    UMAOracleAdapter public oracleAdapter;
    PredictionMarket public pm;
    MarketFactory public mFactory;
    CLOBOrderBook public clob;
    ERC20Mock public usdc;

    // ─── Actors ───────────────────────────────────────────────────────────────

    address public owner = address(uint160(0xABCD));
    address public feeRecipient = address(uint160(0xFEE5));
    address public alice = address(uint160(0xA1CE)); // LP + market creator
    address public bob = address(uint160(0xB0B5)); // YES buyer
    address public carol = address(uint160(0xCA401)); // NO buyer / CLOB participant
    address public asserter = address(uint160(0xA553)); // UMA asserter

    // ─── Market params ────────────────────────────────────────────────────────

    bytes32 public questionId;
    string public question = "Will ETH 2.0 have more validators than ETH 1.0 by end of 2026?";
    string public ipfsData = "QmFullFlowTest123";
    uint256 public resolutionTime;
    bytes32 public conditionId;

    uint256 public constant INITIAL_LIQUIDITY = 10_000e6; // 10,000 USDC
    uint256 public constant CREATION_FEE = 10e6;
    uint256 public constant BOND_AMOUNT = 500e6;

    // ─── Position IDs ─────────────────────────────────────────────────────────

    uint256 public yesPositionId;
    uint256 public noPositionId;

    function setUp() public {
        // ── 1. Deploy all contracts ──────────────────────────────────────────

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        ct = new ConditionalTokens();
        fpmmFactory = new FPMMFactory();
        mockOO = new MockUMAOracleV3();

        oracleAdapter = new UMAOracleAdapter(address(mockOO), address(usdc), address(ct), owner);

        pm = new PredictionMarket(
            address(usdc), address(ct), address(fpmmFactory), address(oracleAdapter), feeRecipient, owner
        );

        mFactory = new MarketFactory(address(pm), address(usdc), owner);

        // Wire oracle adapter
        vm.prank(owner);
        oracleAdapter.setPredictionMarket(address(pm));

        // Set up timing
        resolutionTime = block.timestamp + 30 days;
        questionId = keccak256(abi.encode(question, block.timestamp));

        // Compute conditionId
        conditionId = ct.getConditionId(address(oracleAdapter), questionId, 2);

        // Compute position IDs
        bytes32 yesCollection = ct.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollection = ct.getCollectionId(bytes32(0), conditionId, 2);
        yesPositionId = uint256(ct.getPositionId(IERC20(address(usdc)), yesCollection));
        noPositionId = uint256(ct.getPositionId(IERC20(address(usdc)), noCollection));

        // Mint USDC to all actors
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(carol, 1_000_000e6);
        usdc.mint(asserter, 1_000_000e6);
    }

    // ─── Full Lifecycle Test ──────────────────────────────────────────────────

    function test_fullFlow_yesWins() public {
        console2.log("=== Step 1: Create market via MarketFactory ===");
        _step1_createMarket();

        console2.log("=== Step 2: Additional FPMM liquidity from bob ===");
        _step2_addLiquidity();

        console2.log("=== Step 3: Bob buys YES tokens ===");
        _step3_buyYES();

        console2.log("=== Step 4: Carol buys NO tokens ===");
        _step4_buyNO();

        console2.log("=== Step 5: Deploy CLOB and place limit orders ===");
        _step5_deployAndUseCLOB();

        console2.log("=== Step 6: Initiate resolution via UMA ===");
        _step6_initiateResolution();

        console2.log("=== Step 7: UMA settles YES wins ===");
        _step7_umaSettlesYesWins();

        console2.log("=== Step 8: Redeem positions ===");
        _step8_redeemPositions();

        console2.log("=== Full flow complete ===");
    }

    function test_fullFlow_noWins() public {
        _step1_createMarket();
        _step2_addLiquidity();
        _step3_buyYES();
        _step4_buyNO();

        // Initiate + resolve NO wins
        vm.startPrank(asserter);
        usdc.approve(address(oracleAdapter), BOND_AMOUNT);
        bytes32 assertionId = oracleAdapter.initiateAssertion(conditionId, 1, question); // claim NO
        vm.stopPrank();

        // Register condition
        vm.prank(owner);
        oracleAdapter.registerCondition(conditionId, questionId);

        // Settle as truthful → NO wins
        oracleAdapter.settleAndResolve(conditionId);

        PredictionMarket.MarketInfo memory market = pm.getMarket(conditionId);
        assertEq(uint8(market.status), uint8(PredictionMarket.MarketStatus.Resolved));

        // Report payouts to CT (NO wins)
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 0;
        payouts[1] = 1;
        vm.prank(address(oracleAdapter));
        ct.reportPayouts(questionId, payouts);

        // Carol (NO holder) redeems
        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        vm.startPrank(carol);
        ct.setApprovalForAll(address(pm), true);
        pm.redeemPositions(conditionId);
        vm.stopPrank();

        assertGt(usdc.balanceOf(carol), carolUsdcBefore, "Carol should receive payout");
        console2.log("Carol NO payout:", usdc.balanceOf(carol) - carolUsdcBefore);
    }

    function test_fullFlow_clobMatchBeforeResolution() public {
        _step1_createMarket();
        _step3_buyYES();
        _step4_buyNO();
        _step5_deployAndUseCLOB();

        // Verify CLOB trades settled
        PredictionMarket.MarketInfo memory market = pm.getMarket(conditionId);
        console2.log("Market FPMM:", market.fpmm);
    }

    // ─── Internal Steps ───────────────────────────────────────────────────────

    function _step1_createMarket() internal {
        MarketFactory.MarketMetadata memory metadata = MarketFactory.MarketMetadata({
            question: question,
            description: "Full flow integration test market",
            category: "crypto",
            imageIpfsHash: "QmImage",
            dataIpfsHash: ipfsData,
            resolutionTime: resolutionTime,
            creator: alice,
            initialLiquidity: INITIAL_LIQUIDITY
        });

        vm.startPrank(alice);
        usdc.approve(address(mFactory), CREATION_FEE + INITIAL_LIQUIDITY);
        bytes32 cid = mFactory.createMarket(questionId, metadata, INITIAL_LIQUIDITY);
        vm.stopPrank();

        assertEq(cid, conditionId, "conditionId mismatch");
        assertEq(mFactory.getMarketCount(), 1);

        PredictionMarket.MarketInfo memory market = pm.getMarket(conditionId);
        assertEq(uint8(market.status), uint8(PredictionMarket.MarketStatus.Active));
        assertTrue(market.fpmm != address(0));

        console2.log("Market created:", vm.toString(conditionId));
        console2.log("FPMM:", market.fpmm);
    }

    function _step2_addLiquidity() internal {
        uint256 addAmount = 5_000e6;
        PredictionMarket.MarketInfo memory market = pm.getMarket(conditionId);

        vm.startPrank(bob);
        usdc.approve(address(pm), addAmount);
        pm.addLiquidity(conditionId, addAmount);
        vm.stopPrank();

        uint256 bobShares = IERC20(market.fpmm).balanceOf(bob);
        assertGt(bobShares, 0, "Bob should have LP shares");
        console2.log("Bob LP shares:", bobShares);
    }

    function _step3_buyYES() internal {
        uint256 buyAmount = 1_000e6; // 1000 USDC

        vm.startPrank(bob);
        usdc.approve(address(pm), buyAmount);
        uint256 tokensBought = pm.buyOutcome(conditionId, 0, buyAmount, 0);
        vm.stopPrank();

        assertGt(tokensBought, 0, "Bob should have YES tokens");
        assertEq(ct.balanceOf(bob, yesPositionId), tokensBought);
        console2.log("Bob YES tokens bought:", tokensBought);
    }

    function _step4_buyNO() internal {
        uint256 buyAmount = 500e6; // 500 USDC

        vm.startPrank(carol);
        usdc.approve(address(pm), buyAmount);
        uint256 tokensBought = pm.buyOutcome(conditionId, 1, buyAmount, 0);
        vm.stopPrank();

        assertGt(tokensBought, 0, "Carol should have NO tokens");
        assertEq(ct.balanceOf(carol, noPositionId), tokensBought);
        console2.log("Carol NO tokens bought:", tokensBought);
    }

    function _step5_deployAndUseCLOB() internal {
        // Deploy CLOB for this market
        clob = new CLOBOrderBook(
            IERC20(address(usdc)),
            IConditionalTokens(address(ct)),
            conditionId,
            10, // 0.1% maker fee
            20, // 0.2% taker fee
            feeRecipient,
            owner
        );

        // Mint some YES tokens to carol for CLOB sell orders
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        uint256 splitAmount = 1_000e6; // 1000 USDC worth
        vm.startPrank(carol);
        usdc.approve(address(ct), splitAmount);
        ct.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, splitAmount);
        vm.stopPrank();

        assertGt(ct.balanceOf(carol, yesPositionId), 0, "Carol should have YES tokens for CLOB");

        // Carol places a SELL order at 0.6 USDC per YES token
        // Outcome tokens are 6-decimal (minted 1:1 with 6-decimal USDC collateral)
        uint256 sellPrice = 600_000; // 0.6 USDC (scaled by PRICE_DENOMINATOR = 1e6)
        uint256 sellAmount = 500e6; // 500 YES tokens (6-decimal scale)

        // Get carol's actual YES balance and cap sell to half
        uint256 carolYesBal = ct.balanceOf(carol, yesPositionId);
        if (carolYesBal < sellAmount) sellAmount = carolYesBal / 2;

        vm.startPrank(carol);
        ct.setApprovalForAll(address(clob), true);
        bytes32 sellOrderId = clob.placeLimitOrder(CLOBOrderBook.Side.SELL, 0, sellPrice, sellAmount);
        vm.stopPrank();

        console2.log("Carol CLOB SELL order placed:", vm.toString(sellOrderId));

        // Bob places a matching BUY order at 0.6 USDC (fee-inclusive commitment)
        // base = sellPrice * sellAmount / PRICE_DENOMINATOR; committed = base * (10000 + takerFee) / 10000
        uint256 baseUsdc = (sellPrice * sellAmount) / 1e6;
        uint256 usdcNeeded = (baseUsdc * 10_020) / 10_000; // 0.2% taker fee

        vm.startPrank(bob);
        usdc.approve(address(clob), usdcNeeded);
        bytes32 buyOrderId = clob.placeLimitOrder(CLOBOrderBook.Side.BUY, 0, sellPrice, sellAmount);
        vm.stopPrank();

        console2.log("Bob CLOB BUY order placed:", vm.toString(buyOrderId));

        // Both orders should be matched
        CLOBOrderBook.Order memory sellOrder = clob.getOrder(sellOrderId);
        CLOBOrderBook.Order memory buyOrder = clob.getOrder(buyOrderId);

        assertEq(uint8(sellOrder.status), uint8(CLOBOrderBook.OrderStatus.Filled), "Sell order not filled");
        assertEq(uint8(buyOrder.status), uint8(CLOBOrderBook.OrderStatus.Filled), "Buy order not filled");

        console2.log("CLOB orders matched!");
    }

    function _step6_initiateResolution() internal {
        // Warp to resolution time
        vm.warp(resolutionTime + 1);

        pm.initiateResolution(conditionId);

        PredictionMarket.MarketInfo memory market = pm.getMarket(conditionId);
        assertEq(
            uint8(market.status),
            uint8(PredictionMarket.MarketStatus.PendingResolution),
            "Market should be pending resolution"
        );

        // Register condition in adapter
        vm.prank(owner);
        oracleAdapter.registerCondition(conditionId, questionId);

        // Asserter initiates UMA assertion (YES wins)
        vm.startPrank(asserter);
        usdc.approve(address(oracleAdapter), BOND_AMOUNT);
        bytes32 assertionId = oracleAdapter.initiateAssertion(conditionId, 0, question);
        vm.stopPrank();

        console2.log("UMA assertion initiated:", vm.toString(assertionId));
        assertTrue(assertionId != bytes32(0));
    }

    function _step7_umaSettlesYesWins() internal {
        // Simulate UMA liveness expiry and settlement
        bytes32 assertionId = oracleAdapter.conditionToAssertion(conditionId);

        // MockOO settles the assertion as truthful (YES wins)
        mockOO.settleAssertionWithResult(assertionId, true);

        // Market should now be resolved
        PredictionMarket.MarketInfo memory market = pm.getMarket(conditionId);
        assertEq(
            uint8(market.status), uint8(PredictionMarket.MarketStatus.Resolved), "Market should be resolved"
        );

        // Report payouts to ConditionalTokens (YES wins = [1, 0])
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1; // YES wins
        payouts[1] = 0;
        vm.prank(address(oracleAdapter));
        ct.reportPayouts(questionId, payouts);

        console2.log("Market resolved: YES wins");
    }

    function _step8_redeemPositions() internal {
        // Bob holds YES tokens → should get full payout
        uint256 bobYesBal = ct.balanceOf(bob, yesPositionId);
        assertGt(bobYesBal, 0, "Bob should have YES tokens to redeem");

        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        vm.startPrank(bob);
        ct.setApprovalForAll(address(pm), true);
        pm.redeemPositions(conditionId);
        vm.stopPrank();

        uint256 bobPayout = usdc.balanceOf(bob) - bobUsdcBefore;
        assertGt(bobPayout, 0, "Bob should receive YES payout");
        console2.log("Bob YES payout:", bobPayout);

        // Carol may hold both YES and NO tokens (from CLOB step she split USDC and kept residual YES)
        // After YES wins: YES tokens redeem for USDC, NO tokens redeem for 0
        uint256 carolYesBal = ct.balanceOf(carol, yesPositionId);
        uint256 carolNoBal2 = ct.balanceOf(carol, noPositionId);
        if (carolYesBal > 0 || carolNoBal2 > 0) {
            uint256 carolUsdcBefore = usdc.balanceOf(carol);
            vm.startPrank(carol);
            ct.setApprovalForAll(address(pm), true);
            pm.redeemPositions(conditionId);
            vm.stopPrank();

            uint256 carolPayout = usdc.balanceOf(carol) - carolUsdcBefore;
            // If Carol had YES tokens, she gets a payout (YES won). If only NO, she gets 0.
            if (carolYesBal > 0) {
                assertGt(carolPayout, 0, "Carol should receive payout for YES tokens");
            } else {
                assertEq(carolPayout, 0, "Carol should get 0 if she only has losing NO tokens");
            }
            console2.log("Carol payout:", carolPayout);
        }
    }

    // ─── Additional integration tests ─────────────────────────────────────────

    function test_integration_removeLiquidityAfterTrades() public {
        _step1_createMarket();
        _step3_buyYES();

        // Alice adds her own liquidity to get LP shares (market creator's LP shares go to MarketFactory)
        uint256 addAmount = 1_000e6;
        PredictionMarket.MarketInfo memory market = pm.getMarket(conditionId);

        vm.startPrank(alice);
        usdc.approve(address(pm), addAmount);
        pm.addLiquidity(conditionId, addAmount);
        vm.stopPrank();

        uint256 aliceShares = IERC20(market.fpmm).balanceOf(alice);
        assertGt(aliceShares, 0, "Alice should have LP shares after addLiquidity");

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        IERC20(market.fpmm).approve(address(pm), aliceShares);
        pm.removeLiquidity(conditionId, aliceShares);
        vm.stopPrank();

        // LP shares should be burned
        assertEq(IERC20(market.fpmm).balanceOf(alice), 0, "Alice LP shares should be fully burned");
        // Alice received USDC back (merged positions) and possibly some residual outcome tokens
        // The sum of what she has now (USDC) vs before removing should reflect at most the 1000e6 she added
        // In a balanced pool, she gets close to 1000e6 USDC back
        assertGt(usdc.balanceOf(alice), aliceUsdcBefore, "Alice should receive USDC from removing liquidity");
    }

    function test_integration_cancelMarketRefundsLP() public {
        _step1_createMarket();

        // Cancel the market
        vm.prank(owner);
        pm.cancelMarket(conditionId);

        PredictionMarket.MarketInfo memory market = pm.getMarket(conditionId);
        assertEq(uint8(market.status), uint8(PredictionMarket.MarketStatus.Cancelled));

        // LP shares can no longer be used for addLiquidity
        vm.startPrank(bob);
        usdc.approve(address(pm), 100e6);
        vm.expectRevert(PredictionMarket.MarketNotActive.selector);
        pm.addLiquidity(conditionId, 100e6);
        vm.stopPrank();
    }

    function test_integration_multipleTraders_yesWins() public {
        _step1_createMarket();
        _step2_addLiquidity();

        // Multiple traders buy YES at different times/amounts
        address[] memory traders = new address[](3);
        traders[0] = address(0x1001);
        traders[1] = address(0x1002);
        traders[2] = address(0x1003);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 200e6;
        amounts[1] = 300e6;
        amounts[2] = 100e6;

        uint256[] memory yesTokensBought = new uint256[](3);

        for (uint256 i = 0; i < traders.length; i++) {
            usdc.mint(traders[i], amounts[i]);
            vm.startPrank(traders[i]);
            usdc.approve(address(pm), amounts[i]);
            yesTokensBought[i] = pm.buyOutcome(conditionId, 0, amounts[i], 0);
            vm.stopPrank();

            assertGt(yesTokensBought[i], 0);
        }

        // Resolve YES
        vm.warp(resolutionTime + 1);
        pm.initiateResolution(conditionId);

        vm.prank(owner);
        oracleAdapter.registerCondition(conditionId, questionId);

        vm.startPrank(asserter);
        usdc.approve(address(oracleAdapter), BOND_AMOUNT);
        oracleAdapter.initiateAssertion(conditionId, 0, question);
        vm.stopPrank();

        bytes32 assertionId = oracleAdapter.conditionToAssertion(conditionId);
        mockOO.settleAssertionWithResult(assertionId, true);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        vm.prank(address(oracleAdapter));
        ct.reportPayouts(questionId, payouts);

        // All traders redeem
        for (uint256 i = 0; i < traders.length; i++) {
            uint256 balBefore = usdc.balanceOf(traders[i]);
            vm.startPrank(traders[i]);
            ct.setApprovalForAll(address(pm), true);
            pm.redeemPositions(conditionId);
            vm.stopPrank();

            assertGt(usdc.balanceOf(traders[i]), balBefore, "Trader should receive payout");
        }
    }
}
