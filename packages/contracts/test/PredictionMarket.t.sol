// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {FPMMFactory, FixedProductMarketMaker} from "../src/FPMMFactory.sol";
import {UMAOracleAdapter} from "../src/UMAOracleAdapter.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockUMAOracleV3} from "./mocks/MockUMAOracleV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PredictionMarketTest is Test {
    ConditionalTokens public ct;
    FPMMFactory public fpmmFactory;
    UMAOracleAdapter public oracleAdapter;
    PredictionMarket public pm;
    ERC20Mock public usdc;
    MockUMAOracleV3 public mockOO;

    address public owner = address(uint160(0xABCD));
    address public feeRecipient = address(uint160(0xFEE5));
    address public alice = address(uint160(0xA1CE));
    address public bob = address(uint160(0xB0B5));

    bytes32 public questionId = keccak256("Will ETH reach $10k in 2026?");
    string public question = "Will ETH reach $10k in 2026?";
    string public ipfsHash = "QmTest123";
    uint256 public resolutionTime;

    uint256 public constant INITIAL_LIQUIDITY = 100e6; // 100 USDC (minimum)
    uint256 public constant LARGE_LIQUIDITY = 10_000e6;

    bytes32 public conditionId;

    function setUp() public {
        resolutionTime = block.timestamp + 30 days;

        ct = new ConditionalTokens();
        fpmmFactory = new FPMMFactory();
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        mockOO = new MockUMAOracleV3();

        // Deploy oracle adapter
        oracleAdapter = new UMAOracleAdapter(address(mockOO), address(usdc), address(ct), owner);

        // Deploy prediction market
        pm = new PredictionMarket(
            address(usdc), address(ct), address(fpmmFactory), address(oracleAdapter), feeRecipient, owner
        );

        // Wire oracle adapter to prediction market
        vm.prank(owner);
        oracleAdapter.setPredictionMarket(address(pm));

        // Mint USDC
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(owner, 100_000e6);

        // Compute expected conditionId
        conditionId = ct.getConditionId(address(oracleAdapter), questionId, 2);
    }

    // ─── createMarket ─────────────────────────────────────────────────────────

    function test_createMarket_basic() public {
        vm.startPrank(alice);
        usdc.approve(address(pm), INITIAL_LIQUIDITY);
        bytes32 cid = pm.createMarket(questionId, question, ipfsHash, resolutionTime, INITIAL_LIQUIDITY);
        vm.stopPrank();

        assertEq(cid, conditionId);

        PredictionMarket.MarketInfo memory market = pm.getMarket(cid);
        assertEq(market.conditionId, cid);
        assertEq(market.creator, alice);
        assertEq(market.question, question);
        assertEq(market.ipfsHash, ipfsHash);
        assertEq(market.resolutionTime, resolutionTime);
        assertEq(uint8(market.status), uint8(PredictionMarket.MarketStatus.Active));
        assertTrue(market.fpmm != address(0));
    }

    function test_createMarket_emitsEvent() public {
        vm.startPrank(alice);
        usdc.approve(address(pm), INITIAL_LIQUIDITY);

        vm.expectEmit(true, true, false, true);
        emit PredictionMarket.MarketCreated(conditionId, alice, question, ipfsHash, resolutionTime);
        pm.createMarket(questionId, question, ipfsHash, resolutionTime, INITIAL_LIQUIDITY);
        vm.stopPrank();
    }

    function test_createMarket_lpSharesReturnedToCreator() public {
        vm.startPrank(alice);
        usdc.approve(address(pm), INITIAL_LIQUIDITY);
        bytes32 cid = pm.createMarket(questionId, question, ipfsHash, resolutionTime, INITIAL_LIQUIDITY);
        vm.stopPrank();

        PredictionMarket.MarketInfo memory market = pm.getMarket(cid);
        uint256 aliceLPShares = IERC20(market.fpmm).balanceOf(alice);
        assertGt(aliceLPShares, 0);
    }

    function test_createMarket_revert_insufficientLiquidity() public {
        vm.startPrank(alice);
        usdc.approve(address(pm), 50e6);
        vm.expectRevert(PredictionMarket.InsufficientInitialLiquidity.selector);
        pm.createMarket(questionId, question, ipfsHash, resolutionTime, 50e6);
        vm.stopPrank();
    }

    function test_createMarket_revert_invalidResolutionTime() public {
        vm.startPrank(alice);
        usdc.approve(address(pm), INITIAL_LIQUIDITY);
        vm.expectRevert(PredictionMarket.InvalidResolutionTime.selector);
        pm.createMarket(questionId, question, ipfsHash, block.timestamp - 1, INITIAL_LIQUIDITY);
        vm.stopPrank();
    }

    function test_createMarket_revert_duplicate() public {
        vm.startPrank(alice);
        usdc.approve(address(pm), INITIAL_LIQUIDITY * 2);
        pm.createMarket(questionId, question, ipfsHash, resolutionTime, INITIAL_LIQUIDITY);

        vm.expectRevert(PredictionMarket.MarketAlreadyExists.selector);
        pm.createMarket(questionId, question, ipfsHash, resolutionTime, INITIAL_LIQUIDITY);
        vm.stopPrank();
    }

    function test_createMarket_revert_paused() public {
        vm.prank(owner);
        pm.pause();

        vm.startPrank(alice);
        usdc.approve(address(pm), INITIAL_LIQUIDITY);
        vm.expectRevert(); // Pausable: paused
        pm.createMarket(questionId, question, ipfsHash, resolutionTime, INITIAL_LIQUIDITY);
        vm.stopPrank();
    }

    // ─── addLiquidity ─────────────────────────────────────────────────────────

    function test_addLiquidity_basic() public {
        _createMarket(alice, INITIAL_LIQUIDITY);

        uint256 additionalLiquidity = 200e6;
        vm.startPrank(bob);
        usdc.approve(address(pm), additionalLiquidity);
        pm.addLiquidity(conditionId, additionalLiquidity);
        vm.stopPrank();

        PredictionMarket.MarketInfo memory market = pm.getMarket(conditionId);
        uint256 bobShares = IERC20(market.fpmm).balanceOf(bob);
        assertGt(bobShares, 0);
    }

    function test_addLiquidity_emitsEvent() public {
        _createMarket(alice, INITIAL_LIQUIDITY);

        vm.startPrank(bob);
        usdc.approve(address(pm), 200e6);

        vm.expectEmit(true, true, false, false);
        emit PredictionMarket.LiquidityAdded(conditionId, bob, 200e6, 0); // shares unknown
        pm.addLiquidity(conditionId, 200e6);
        vm.stopPrank();
    }

    function test_addLiquidity_revert_notActive() public {
        _createMarket(alice, INITIAL_LIQUIDITY);

        vm.prank(owner);
        pm.cancelMarket(conditionId);

        vm.startPrank(bob);
        usdc.approve(address(pm), 200e6);
        vm.expectRevert(PredictionMarket.MarketNotActive.selector);
        pm.addLiquidity(conditionId, 200e6);
        vm.stopPrank();
    }

    function test_addLiquidity_revert_zero() public {
        _createMarket(alice, INITIAL_LIQUIDITY);

        vm.startPrank(bob);
        vm.expectRevert(PredictionMarket.ZeroAmount.selector);
        pm.addLiquidity(conditionId, 0);
        vm.stopPrank();
    }

    // ─── removeLiquidity ──────────────────────────────────────────────────────

    function test_removeLiquidity_basic() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        PredictionMarket.MarketInfo memory market = pm.getMarket(conditionId);
        uint256 aliceShares = IERC20(market.fpmm).balanceOf(alice);
        assertGt(aliceShares, 0);

        vm.startPrank(alice);
        IERC20(market.fpmm).approve(address(pm), aliceShares);
        pm.removeLiquidity(conditionId, aliceShares);
        vm.stopPrank();

        assertEq(IERC20(market.fpmm).balanceOf(alice), 0);
    }

    // ─── buyOutcome ───────────────────────────────────────────────────────────

    function test_buyOutcome_yes() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        uint256 usdcAmount = 100e6;
        vm.startPrank(bob);
        usdc.approve(address(pm), usdcAmount);
        uint256 tokensBought = pm.buyOutcome(conditionId, 0, usdcAmount, 0);
        vm.stopPrank();

        assertGt(tokensBought, 0);

        bytes32 yesCollection = ct.getCollectionId(bytes32(0), conditionId, 1);
        uint256 yesId = uint256(ct.getPositionId(IERC20(address(usdc)), yesCollection));
        assertEq(ct.balanceOf(bob, yesId), tokensBought);
    }

    function test_buyOutcome_no() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        uint256 usdcAmount = 100e6;
        vm.startPrank(bob);
        usdc.approve(address(pm), usdcAmount);
        uint256 tokensBought = pm.buyOutcome(conditionId, 1, usdcAmount, 0);
        vm.stopPrank();

        assertGt(tokensBought, 0);
    }

    function test_buyOutcome_protocolFeeDeducted() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        uint256 usdcAmount = 1000e6;
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);

        vm.startPrank(bob);
        usdc.approve(address(pm), usdcAmount);
        pm.buyOutcome(conditionId, 0, usdcAmount, 0);
        vm.stopPrank();

        uint256 expectedFee = (usdcAmount * 50) / 10_000;
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBefore + expectedFee);
    }

    function test_buyOutcome_emitsEvent() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        vm.startPrank(bob);
        usdc.approve(address(pm), 100e6);
        vm.expectEmit(true, true, false, false);
        emit PredictionMarket.OutcomeBought(conditionId, bob, 0, 100e6, 0);
        pm.buyOutcome(conditionId, 0, 100e6, 0);
        vm.stopPrank();
    }

    function test_buyOutcome_revert_zeroAmount() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        vm.startPrank(bob);
        vm.expectRevert(PredictionMarket.ZeroAmount.selector);
        pm.buyOutcome(conditionId, 0, 0, 0);
        vm.stopPrank();
    }

    function test_buyOutcome_revert_invalidOutcome() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        vm.startPrank(bob);
        usdc.approve(address(pm), 100e6);
        vm.expectRevert(PredictionMarket.InvalidOutcomeIndex.selector);
        pm.buyOutcome(conditionId, 5, 100e6, 0);
        vm.stopPrank();
    }

    function test_buyOutcome_revert_marketNotActive() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        vm.prank(owner);
        pm.cancelMarket(conditionId);

        vm.startPrank(bob);
        usdc.approve(address(pm), 100e6);
        vm.expectRevert(PredictionMarket.MarketNotActive.selector);
        pm.buyOutcome(conditionId, 0, 100e6, 0);
        vm.stopPrank();
    }

    function test_buyOutcome_revert_paused() public {
        _createMarket(alice, LARGE_LIQUIDITY);
        vm.prank(owner);
        pm.pause();

        vm.startPrank(bob);
        usdc.approve(address(pm), 100e6);
        vm.expectRevert(); // Pausable
        pm.buyOutcome(conditionId, 0, 100e6, 0);
        vm.stopPrank();
    }

    // ─── sellOutcome ──────────────────────────────────────────────────────────

    function test_sellOutcome_basic() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        uint256 buyAmount = 500e6;
        vm.startPrank(bob);
        usdc.approve(address(pm), buyAmount);
        pm.buyOutcome(conditionId, 0, buyAmount, 0);

        bytes32 yesCollection = ct.getCollectionId(bytes32(0), conditionId, 1);
        uint256 yesId = uint256(ct.getPositionId(IERC20(address(usdc)), yesCollection));
        uint256 yesBal = ct.balanceOf(bob, yesId);
        assertGt(yesBal, 0);

        uint256 returnAmount = 100e6;
        PredictionMarket.MarketInfo memory market = pm.getMarket(conditionId);
        uint256 tokensToSell = FixedProductMarketMaker(market.fpmm).calcSellAmount(returnAmount, 0);

        uint256 usdcBefore = usdc.balanceOf(bob);
        ct.setApprovalForAll(address(pm), true);
        pm.sellOutcome(conditionId, 0, returnAmount, tokensToSell + 1e18);
        vm.stopPrank();

        uint256 protocolFee = (returnAmount * 50) / 10_000;
        assertEq(usdc.balanceOf(bob), usdcBefore + returnAmount - protocolFee);
    }

    // ─── initiateResolution ───────────────────────────────────────────────────

    function test_initiateResolution() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        vm.warp(resolutionTime + 1);
        pm.initiateResolution(conditionId);

        PredictionMarket.MarketInfo memory market = pm.getMarket(conditionId);
        assertEq(uint8(market.status), uint8(PredictionMarket.MarketStatus.PendingResolution));
    }

    function test_initiateResolution_revert_tooEarly() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        vm.expectRevert(PredictionMarket.InvalidResolutionTime.selector);
        pm.initiateResolution(conditionId);
    }

    function test_initiateResolution_revert_notFound() public {
        vm.expectRevert(PredictionMarket.MarketNotFound.selector);
        pm.initiateResolution(bytes32(uint256(1)));
    }

    // ─── resolveMarket ────────────────────────────────────────────────────────

    function test_resolveMarket_yesWins() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.prank(address(oracleAdapter));
        pm.resolveMarket(conditionId, payouts);

        PredictionMarket.MarketInfo memory market = pm.getMarket(conditionId);
        assertEq(uint8(market.status), uint8(PredictionMarket.MarketStatus.Resolved));
    }

    function test_resolveMarket_revert_notOracleAdapter() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;

        vm.prank(alice);
        vm.expectRevert(PredictionMarket.OnlyOracleAdapter.selector);
        pm.resolveMarket(conditionId, payouts);
    }

    function test_resolveMarket_revert_alreadyResolved() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;

        vm.prank(address(oracleAdapter));
        pm.resolveMarket(conditionId, payouts);

        vm.prank(address(oracleAdapter));
        vm.expectRevert(PredictionMarket.MarketAlreadyResolved.selector);
        pm.resolveMarket(conditionId, payouts);
    }

    function test_resolveMarket_revert_invalidPayouts_allZero() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        uint256[] memory payouts = new uint256[](2);

        vm.prank(address(oracleAdapter));
        vm.expectRevert(PredictionMarket.InvalidPayouts.selector);
        pm.resolveMarket(conditionId, payouts);
    }

    function test_resolveMarket_revert_invalidPayouts_wrongLength() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        uint256[] memory payouts = new uint256[](3);
        payouts[0] = 1;

        vm.prank(address(oracleAdapter));
        vm.expectRevert(PredictionMarket.InvalidPayouts.selector);
        pm.resolveMarket(conditionId, payouts);
    }

    // ─── cancelMarket ─────────────────────────────────────────────────────────

    function test_cancelMarket() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        vm.prank(owner);
        pm.cancelMarket(conditionId);

        PredictionMarket.MarketInfo memory market = pm.getMarket(conditionId);
        assertEq(uint8(market.status), uint8(PredictionMarket.MarketStatus.Cancelled));
    }

    function test_cancelMarket_emitsEvent() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit PredictionMarket.MarketCancelled(conditionId);
        pm.cancelMarket(conditionId);
    }

    function test_cancelMarket_revert_notOwner() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        vm.prank(alice);
        vm.expectRevert();
        pm.cancelMarket(conditionId);
    }

    function test_cancelMarket_revert_notFound() public {
        vm.prank(owner);
        vm.expectRevert(PredictionMarket.MarketNotFound.selector);
        pm.cancelMarket(bytes32(uint256(999)));
    }

    function test_cancelMarket_revert_alreadyResolved() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        vm.prank(address(oracleAdapter));
        pm.resolveMarket(conditionId, payouts);

        vm.prank(owner);
        vm.expectRevert(PredictionMarket.MarketAlreadyResolved.selector);
        pm.cancelMarket(conditionId);
    }

    // ─── redeemPositions ──────────────────────────────────────────────────────

    function test_redeemPositions_yesWins() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        // Bob buys YES
        uint256 buyAmount = 100e6;
        vm.startPrank(bob);
        usdc.approve(address(pm), buyAmount);
        pm.buyOutcome(conditionId, 0, buyAmount, 0);
        vm.stopPrank();

        // Resolve YES
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        vm.prank(address(oracleAdapter));
        pm.resolveMarket(conditionId, payouts);

        // Also need to report payouts to ConditionalTokens
        vm.prank(address(oracleAdapter));
        ct.reportPayouts(questionId, payouts);

        // Bob redeems
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        vm.startPrank(bob);
        ct.setApprovalForAll(address(pm), true);
        pm.redeemPositions(conditionId);
        vm.stopPrank();

        assertGt(usdc.balanceOf(bob), bobUsdcBefore);
    }

    function test_redeemPositions_revert_notResolved() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        vm.startPrank(bob);
        usdc.approve(address(pm), 100e6);
        pm.buyOutcome(conditionId, 0, 100e6, 0);
        ct.setApprovalForAll(address(pm), true);
        vm.expectRevert(PredictionMarket.MarketNotActive.selector);
        pm.redeemPositions(conditionId);
        vm.stopPrank();
    }

    function test_redeemPositions_revert_nothingToRedeem() public {
        _createMarket(alice, LARGE_LIQUIDITY);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        vm.prank(address(oracleAdapter));
        pm.resolveMarket(conditionId, payouts);
        vm.prank(address(oracleAdapter));
        ct.reportPayouts(questionId, payouts);

        vm.startPrank(bob); // bob has no tokens
        ct.setApprovalForAll(address(pm), true);
        vm.expectRevert(PredictionMarket.NothingToRedeem.selector);
        pm.redeemPositions(conditionId);
        vm.stopPrank();
    }

    // ─── Protocol fee admin ───────────────────────────────────────────────────

    function test_setProtocolFee() public {
        vm.prank(owner);
        pm.setProtocolFee(100);
        assertEq(pm.protocolFeeBps(), 100);
    }

    function test_setProtocolFee_revert_tooHigh() public {
        vm.prank(owner);
        vm.expectRevert(PredictionMarket.InvalidFee.selector);
        pm.setProtocolFee(501);
    }

    function test_setProtocolFee_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        pm.setProtocolFee(100);
    }

    function test_setFeeRecipient() public {
        address newRecipient = address(0x1234);
        vm.prank(owner);
        pm.setFeeRecipient(newRecipient);
        assertEq(pm.feeRecipient(), newRecipient);
    }

    function test_setFeeRecipient_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(PredictionMarket.ZeroAddress.selector);
        pm.setFeeRecipient(address(0));
    }

    // ─── pause / unpause ──────────────────────────────────────────────────────

    function test_pause_unpause() public {
        vm.prank(owner);
        pm.pause();
        assertTrue(pm.paused());

        vm.prank(owner);
        pm.unpause();
        assertFalse(pm.paused());
    }

    function test_pause_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        pm.pause();
    }

    function test_unpause_revert_notOwner() public {
        vm.prank(owner);
        pm.pause();

        vm.prank(alice);
        vm.expectRevert();
        pm.unpause();
    }

    // ─── Access control ───────────────────────────────────────────────────────

    function test_accessControl_ownerCanPause() public {
        vm.prank(owner);
        pm.pause();
        assertTrue(pm.paused());
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _createMarket(address creator, uint256 liquidity) internal {
        vm.startPrank(creator);
        usdc.approve(address(pm), liquidity);
        pm.createMarket(questionId, question, ipfsHash, resolutionTime, liquidity);
        vm.stopPrank();
    }
}
