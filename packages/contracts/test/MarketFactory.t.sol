// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {FPMMFactory} from "../src/FPMMFactory.sol";
import {UMAOracleAdapter} from "../src/UMAOracleAdapter.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockUMAOracleV3} from "./mocks/MockUMAOracleV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MarketFactoryTest is Test {
    ConditionalTokens public ct;
    FPMMFactory public fpmmFactory;
    UMAOracleAdapter public oracleAdapter;
    PredictionMarket public pm;
    MarketFactory public factory;
    ERC20Mock public usdc;
    MockUMAOracleV3 public mockOO;

    address public owner = address(uint160(0xABCD));
    address public feeRecipient = address(uint160(0xFEE5));
    address public alice = address(uint160(0xA1CE));
    address public bob = address(uint160(0xB0B5));

    bytes32 public questionId = keccak256("Will Polygon flip Ethereum in 2027?");
    string public question = "Will Polygon flip Ethereum in 2027?";
    string public description = "Resolves YES if Polygon market cap > Ethereum on 2027-12-31";
    string public category = "crypto";
    string public imageIpfsHash = "QmImage123";
    string public dataIpfsHash = "QmData456";

    uint256 public constant CREATION_FEE = 10e6; // 10 USDC
    uint256 public constant INITIAL_LIQUIDITY = 100e6;

    function setUp() public {
        ct = new ConditionalTokens();
        fpmmFactory = new FPMMFactory();
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        mockOO = new MockUMAOracleV3();

        oracleAdapter = new UMAOracleAdapter(address(mockOO), address(usdc), address(ct), owner);

        pm = new PredictionMarket(
            address(usdc), address(ct), address(fpmmFactory), address(oracleAdapter), feeRecipient, owner
        );

        vm.prank(owner);
        oracleAdapter.setPredictionMarket(address(pm));

        factory = new MarketFactory(address(pm), address(usdc), owner);

        // Mint USDC
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
    }

    function _buildMetadata(uint256 resolutionTime) internal view returns (MarketFactory.MarketMetadata memory) {
        return MarketFactory.MarketMetadata({
            question: question,
            description: description,
            category: category,
            imageIpfsHash: imageIpfsHash,
            dataIpfsHash: dataIpfsHash,
            resolutionTime: resolutionTime,
            creator: alice,
            initialLiquidity: INITIAL_LIQUIDITY
        });
    }

    // ─── createMarket ─────────────────────────────────────────────────────────

    function test_createMarket_basic() public {
        uint256 resolutionTime = block.timestamp + 2 hours + 1;
        MarketFactory.MarketMetadata memory metadata = _buildMetadata(resolutionTime);

        uint256 totalRequired = CREATION_FEE + INITIAL_LIQUIDITY;

        vm.startPrank(alice);
        usdc.approve(address(factory), totalRequired);
        bytes32 conditionId = factory.createMarket(questionId, metadata, INITIAL_LIQUIDITY);
        vm.stopPrank();

        assertTrue(conditionId != bytes32(0));
        assertEq(factory.getMarketCount(), 1);

        // Verify metadata stored
        MarketFactory.MarketMetadata memory stored = factory.getMarketMetadata(conditionId);
        assertEq(stored.question, question);
        assertEq(stored.description, description);
        assertEq(stored.category, category);
        assertEq(stored.imageIpfsHash, imageIpfsHash);
        assertEq(stored.dataIpfsHash, dataIpfsHash);
        assertEq(stored.creator, alice);
    }

    function test_createMarket_emitsEvent() public {
        uint256 resolutionTime = block.timestamp + 2 hours + 1;
        MarketFactory.MarketMetadata memory metadata = _buildMetadata(resolutionTime);

        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_FEE + INITIAL_LIQUIDITY);

        vm.expectEmit(false, true, false, true);
        emit MarketFactory.MarketDeployed(bytes32(0), alice, question, dataIpfsHash, resolutionTime);
        factory.createMarket(questionId, metadata, INITIAL_LIQUIDITY);
        vm.stopPrank();
    }

    function test_createMarket_creationFeeAccrued() public {
        uint256 resolutionTime = block.timestamp + 2 hours + 1;
        MarketFactory.MarketMetadata memory metadata = _buildMetadata(resolutionTime);

        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_FEE + INITIAL_LIQUIDITY);
        factory.createMarket(questionId, metadata, INITIAL_LIQUIDITY);
        vm.stopPrank();

        assertEq(factory.accruedFees(), CREATION_FEE);
    }

    function test_createMarket_revert_resolutionTimeTooSoon() public {
        uint256 resolutionTime = block.timestamp + 30 minutes; // < 1 hour
        MarketFactory.MarketMetadata memory metadata = _buildMetadata(resolutionTime);

        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_FEE + INITIAL_LIQUIDITY);
        vm.expectRevert(MarketFactory.ResolutionTimeTooSoon.selector);
        factory.createMarket(questionId, metadata, INITIAL_LIQUIDITY);
        vm.stopPrank();
    }

    function test_createMarket_revert_resolutionTimeTooFar() public {
        uint256 resolutionTime = block.timestamp + 400 days; // > 365 days
        MarketFactory.MarketMetadata memory metadata = _buildMetadata(resolutionTime);

        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_FEE + INITIAL_LIQUIDITY);
        vm.expectRevert(MarketFactory.ResolutionTimeTooFar.selector);
        factory.createMarket(questionId, metadata, INITIAL_LIQUIDITY);
        vm.stopPrank();
    }

    function test_createMarket_revert_pastResolutionTime() public {
        uint256 resolutionTime = block.timestamp - 1;
        MarketFactory.MarketMetadata memory metadata = _buildMetadata(resolutionTime);

        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_FEE + INITIAL_LIQUIDITY);
        vm.expectRevert(MarketFactory.InvalidResolutionTime.selector);
        factory.createMarket(questionId, metadata, INITIAL_LIQUIDITY);
        vm.stopPrank();
    }

    function test_createMarket_revert_emptyQuestion() public {
        uint256 resolutionTime = block.timestamp + 2 hours + 1;
        MarketFactory.MarketMetadata memory metadata = MarketFactory.MarketMetadata({
            question: "", // empty
            description: description,
            category: category,
            imageIpfsHash: imageIpfsHash,
            dataIpfsHash: dataIpfsHash,
            resolutionTime: resolutionTime,
            creator: alice,
            initialLiquidity: INITIAL_LIQUIDITY
        });

        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_FEE + INITIAL_LIQUIDITY);
        vm.expectRevert(MarketFactory.EmptyQuestion.selector);
        factory.createMarket(questionId, metadata, INITIAL_LIQUIDITY);
        vm.stopPrank();
    }

    function test_createMarket_revert_paused() public {
        vm.prank(owner);
        factory.pause();

        uint256 resolutionTime = block.timestamp + 2 hours + 1;
        MarketFactory.MarketMetadata memory metadata = _buildMetadata(resolutionTime);

        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_FEE + INITIAL_LIQUIDITY);
        vm.expectRevert();
        factory.createMarket(questionId, metadata, INITIAL_LIQUIDITY);
        vm.stopPrank();
    }

    // ─── getMarkets ───────────────────────────────────────────────────────────

    function test_getMarketCount() public {
        assertEq(factory.getMarketCount(), 0);

        _createMarket(alice);
        assertEq(factory.getMarketCount(), 1);
    }

    function test_getAllMarkets() public {
        _createMarket(alice);
        bytes32 qId2 = keccak256("second market?");
        _createMarketWithId(bob, qId2);

        bytes32[] memory all = factory.getAllMarkets();
        assertEq(all.length, 2);
    }

    function test_getMarketsByCreator() public {
        _createMarket(alice);
        bytes32 qId2 = keccak256("another?");
        _createMarketWithId(alice, qId2);
        _createMarketWithId(bob, keccak256("bob market"));

        bytes32[] memory aliceMarkets = factory.getMarketsByCreator(alice);
        bytes32[] memory bobMarkets = factory.getMarketsByCreator(bob);

        assertEq(aliceMarkets.length, 2);
        assertEq(bobMarkets.length, 1);
    }

    function test_getMarketsPaginated() public {
        for (uint256 i = 0; i < 5; i++) {
            bytes32 qId = keccak256(abi.encode("market", i));
            _createMarketWithId(alice, qId);
        }

        bytes32[] memory page1 = factory.getMarketsPaginated(0, 2);
        bytes32[] memory page2 = factory.getMarketsPaginated(2, 2);
        bytes32[] memory page3 = factory.getMarketsPaginated(4, 2); // only 1 remaining

        assertEq(page1.length, 2);
        assertEq(page2.length, 2);
        assertEq(page3.length, 1);
    }

    function test_getMarketsPaginated_outOfRange() public view {
        bytes32[] memory result = factory.getMarketsPaginated(100, 10);
        assertEq(result.length, 0);
    }

    // ─── Admin functions ──────────────────────────────────────────────────────

    function test_setCreationFee() public {
        vm.prank(owner);
        factory.setCreationFee(20e6);
        assertEq(factory.creationFee(), 20e6);
    }

    function test_setCreationFee_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit MarketFactory.CreationFeeUpdated(10e6, 20e6);
        factory.setCreationFee(20e6);
    }

    function test_setCreationFee_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.setCreationFee(20e6);
    }

    function test_setResolutionTimeBounds() public {
        vm.prank(owner);
        factory.setResolutionTimeBounds(2 hours, 180 days);

        assertEq(factory.minResolutionTime(), 2 hours);
        assertEq(factory.maxResolutionTime(), 180 days);
    }

    function test_setResolutionTimeBounds_revert_invalidBounds() public {
        vm.prank(owner);
        vm.expectRevert();
        factory.setResolutionTimeBounds(10 days, 1 days); // min > max
    }

    function test_setResolutionTimeBounds_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.setResolutionTimeBounds(2 hours, 180 days);
    }

    function test_withdrawFees() public {
        _createMarket(alice);

        address treasury = address(0x0000000000000000000000000000000000001234);
        uint256 accruedBefore = factory.accruedFees();
        assertEq(accruedBefore, CREATION_FEE);

        vm.prank(owner);
        factory.withdrawFees(treasury);

        assertEq(factory.accruedFees(), 0);
        assertEq(usdc.balanceOf(treasury), CREATION_FEE);
    }

    function test_withdrawFees_revert_zeroAddress() public {
        _createMarket(alice);

        vm.prank(owner);
        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        factory.withdrawFees(address(0));
    }

    function test_withdrawFees_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.withdrawFees(alice);
    }

    // ─── Pause ────────────────────────────────────────────────────────────────

    function test_pause_unpause() public {
        vm.prank(owner);
        factory.pause();
        assertTrue(factory.paused());

        vm.prank(owner);
        factory.unpause();
        assertFalse(factory.paused());
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _createMarket(address creator) internal returns (bytes32 conditionId) {
        return _createMarketWithId(creator, questionId);
    }

    function _createMarketWithId(address creator, bytes32 qId) internal returns (bytes32 conditionId) {
        uint256 resolutionTime = block.timestamp + 2 hours + 1;
        MarketFactory.MarketMetadata memory metadata = _buildMetadata(resolutionTime);

        usdc.mint(creator, CREATION_FEE + INITIAL_LIQUIDITY);

        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_FEE + INITIAL_LIQUIDITY);
        conditionId = factory.createMarket(qId, metadata, INITIAL_LIQUIDITY);
        vm.stopPrank();
    }
}
