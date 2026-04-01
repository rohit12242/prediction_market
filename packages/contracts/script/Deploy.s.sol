// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {FPMMFactory} from "../src/FPMMFactory.sol";
import {UMAOracleAdapter} from "../src/UMAOracleAdapter.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {CLOBOrderBook} from "../src/CLOBOrderBook.sol";
import {IConditionalTokens} from "../src/interfaces/IConditionalTokens.sol";

/// @title Deploy
/// @notice Deployment script for all prediction market contracts on Polygon.
///
/// Deployment order:
///   1. ConditionalTokens
///   2. FPMMFactory
///   3. UMAOracleAdapter (with placeholder for PredictionMarket)
///   4. PredictionMarket
///   5. MarketFactory
///   6. Wire: UMAOracleAdapter.setPredictionMarket(PredictionMarket)
///
/// Environment variables:
///   PRIVATE_KEY      — deployer private key
///   USDC_ADDRESS     — USDC token address (default: Polygon mainnet USDC)
///   UMA_OO_ADDRESS   — UMA OOV3 address (default: Polygon mainnet)
///   FEE_RECIPIENT    — address to receive protocol fees
///   OWNER            — owner address (defaults to deployer)
contract Deploy is Script {
    // ─── Polygon Mainnet Addresses ────────────────────────────────────────────

    address public constant POLYGON_USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address public constant POLYGON_UMA_OO_V3 = 0x5953f2538F613E05bAED8A5AeFa8e6622467AD3D;

    // ─── Deployed addresses (set during run) ─────────────────────────────────

    address public deployedUsdc;  // real USDC on mainnet/testnet, MockERC20 on local
    ConditionalTokens public conditionalTokens;
    FPMMFactory public fpmmFactory;
    UMAOracleAdapter public oracleAdapter;
    PredictionMarket public predictionMarket;
    MarketFactory public marketFactory;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Configuration
        address usdc = _getOrDeployUSDC(deployer);
        deployedUsdc = usdc;
        address umaOO = _getUMAOO();
        address feeRecipient = _getFeeRecipient(deployer);
        address owner = _getOwner(deployer);

        console2.log("==========================================");
        console2.log("Prediction Market Deployment");
        console2.log("==========================================");
        console2.log("Deployer:         ", deployer);
        console2.log("Owner:            ", owner);
        console2.log("Fee Recipient:    ", feeRecipient);
        console2.log("USDC:             ", usdc);
        console2.log("UMA OOV3:         ", umaOO);
        console2.log("==========================================");

        vm.startBroadcast(deployerKey);

        // ── Step 1: Deploy ConditionalTokens ──────────────────────────────────
        conditionalTokens = new ConditionalTokens();
        console2.log("1. ConditionalTokens:", address(conditionalTokens));

        // ── Step 2: Deploy FPMMFactory ────────────────────────────────────────
        fpmmFactory = new FPMMFactory();
        console2.log("2. FPMMFactory:      ", address(fpmmFactory));

        // ── Step 3: Deploy UMAOracleAdapter ───────────────────────────────────
        //    Note: predictionMarket address is set later via setPredictionMarket
        oracleAdapter = new UMAOracleAdapter(umaOO, usdc, address(conditionalTokens), owner);
        console2.log("3. UMAOracleAdapter: ", address(oracleAdapter));

        // ── Step 4: Deploy PredictionMarket ───────────────────────────────────
        predictionMarket = new PredictionMarket(
            usdc,
            address(conditionalTokens),
            address(fpmmFactory),
            address(oracleAdapter),
            feeRecipient,
            owner
        );
        console2.log("4. PredictionMarket: ", address(predictionMarket));

        // ── Step 5: Deploy MarketFactory ──────────────────────────────────────
        marketFactory = new MarketFactory(address(predictionMarket), usdc, owner);
        console2.log("5. MarketFactory:    ", address(marketFactory));

        // ── Step 6: Wire UMAOracleAdapter → PredictionMarket ──────────────────
        //    If deployer is also the owner, wire immediately.
        //    Otherwise, this must be called manually by the owner.
        if (deployer == owner) {
            oracleAdapter.setPredictionMarket(address(predictionMarket));
            console2.log("6. Wired: OracleAdapter.predictionMarket =", address(predictionMarket));
        } else {
            console2.log("6. MANUAL ACTION REQUIRED:");
            console2.log("   Call: oracleAdapter.setPredictionMarket(predictionMarket)");
            console2.log("   oracleAdapter:", address(oracleAdapter));
            console2.log("   predictionMarket:", address(predictionMarket));
        }

        vm.stopBroadcast();

        // ── Persist addresses ──────────────────────────────────────────────────
        _writeDeployments(usdc);

        // ── Summary ────────────────────────────────────────────────────────────
        _logSummary();
    }

    /// @notice Deploy a CLOBOrderBook for a specific market condition (run per-market)
    function deployCLOBForMarket(
        address usdcAddr,
        address conditionalTokensAddr,
        bytes32 conditionId,
        uint256 makerFeeBps,
        uint256 takerFeeBps,
        address feeRecipient,
        address clobOwner
    ) external returns (address clob) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        CLOBOrderBook clobContract = new CLOBOrderBook(
            IERC20(usdcAddr),
            IConditionalTokens(conditionalTokensAddr),
            conditionId,
            makerFeeBps,
            takerFeeBps,
            feeRecipient,
            clobOwner
        );

        console2.log("CLOBOrderBook deployed:", address(clobContract));
        console2.log("  Condition ID:    ", vm.toString(conditionId));
        console2.log("  Maker fee (bps): ", makerFeeBps);
        console2.log("  Taker fee (bps): ", takerFeeBps);

        vm.stopBroadcast();

        return address(clobContract);
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    function _logSummary() internal view {
        console2.log("");
        console2.log("==========================================");
        console2.log("Deployment Summary");
        console2.log("==========================================");
        console2.log("ConditionalTokens:  ", address(conditionalTokens));
        console2.log("FPMMFactory:        ", address(fpmmFactory));
        console2.log("UMAOracleAdapter:   ", address(oracleAdapter));
        console2.log("PredictionMarket:   ", address(predictionMarket));
        console2.log("MarketFactory:      ", address(marketFactory));
        console2.log("==========================================");
        console2.log("");
        console2.log("Post-deployment checklist:");
        console2.log("  [ ] oracleAdapter.setPredictionMarket(predictionMarket)  [if owner != deployer]");
        console2.log("  [ ] Verify all contracts on Polygonscan");
        console2.log("  [ ] Set MarketFactory creation fee via setCreationFee()");
        console2.log("  [ ] Set resolution time bounds via setResolutionTimeBounds()");
        console2.log("  [ ] Fund asserter wallets with USDC for UMA bonds (min 500 USDC each)");
        console2.log("  [ ] For each market: deployCLOBForMarket() with conditionId");
    }

    // ─── Deployment helpers ───────────────────────────────────────────────────

    /// @notice Returns real USDC on Polygon; deploys + mints MockERC20 on local Anvil (chainid 31337).
    function _getOrDeployUSDC(address recipient) internal returns (address) {
        if (block.chainid == 31337) {
            ERC20Mock mock = new ERC20Mock();
            mock.mint(recipient, 1_000_000e6); // 1M USDC for seeding markets
            console2.log("  [local] MockUSDC deployed:", address(mock));
            return address(mock);
        }
        try vm.envAddress("USDC_ADDRESS") returns (address addr) {
            if (addr != address(0)) return addr;
        } catch {}
        return POLYGON_USDC;
    }

    /// @notice Writes all deployed contract addresses to deployments/<chain>.json
    function _writeDeployments(address usdc) internal {
        string memory obj = "out";
        vm.serializeAddress(obj, "USDC",               usdc);
        vm.serializeAddress(obj, "ConditionalTokens",  address(conditionalTokens));
        vm.serializeAddress(obj, "FPMMFactory",        address(fpmmFactory));
        vm.serializeAddress(obj, "UMAOracleAdapter",   address(oracleAdapter));
        vm.serializeAddress(obj, "PredictionMarket",   address(predictionMarket));
        string memory finalJson = vm.serializeAddress(obj, "MarketFactory", address(marketFactory));

        string memory chain = _chainName();
        string memory path  = string.concat("deployments/", chain, ".json");
        vm.writeJson(finalJson, path);
        console2.log("");
        console2.log("Saved deployments to:", path);
    }

    function _chainName() internal view returns (string memory) {
        uint256 id = block.chainid;
        if (id == 31337)  return "localhost";
        if (id == 80002)  return "polygon_amoy";
        if (id == 137)    return "polygon";
        return vm.toString(id);
    }

    function _getUMAOO() internal view returns (address) {
        try vm.envAddress("UMA_OO_ADDRESS") returns (address addr) {
            if (addr != address(0)) return addr;
        } catch {}
        return POLYGON_UMA_OO_V3;
    }

    function _getFeeRecipient(address deployer) internal view returns (address) {
        try vm.envAddress("FEE_RECIPIENT") returns (address addr) {
            if (addr != address(0)) return addr;
        } catch {}
        return deployer;
    }

    function _getOwner(address deployer) internal view returns (address) {
        try vm.envAddress("OWNER") returns (address addr) {
            if (addr != address(0)) return addr;
        } catch {}
        return deployer;
    }
}
