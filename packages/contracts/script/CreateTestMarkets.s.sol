// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MarketFactory} from "../src/MarketFactory.sol";

/// @title CreateTestMarkets
/// @notice Seeds 10 realistic prediction markets (politics, crypto, sports) for dev/testnet use.
///
/// Prerequisites:
///   - Deploy.s.sol must have been run first (reads deployments/<chain>.json)
///   - Deployer wallet must hold sufficient USDC (10 * (initialLiquidity + creationFee))
///   - On local Anvil, MockUSDC is minted automatically via the deployed mock contract
///
/// Usage:
///   forge script script/CreateTestMarkets.s.sol --rpc-url localhost --broadcast -vvvv
///   forge script script/CreateTestMarkets.s.sol --rpc-url polygon_amoy --broadcast -vvvv
contract CreateTestMarkets is Script {
    // ─── Config ───────────────────────────────────────────────────────────────

    /// Initial USDC liquidity per market (100 USDC)
    uint256 public constant INITIAL_LIQUIDITY = 100e6;

    // ─── Internal structs ─────────────────────────────────────────────────────

    struct MarketSeed {
        bytes32 questionId;
        string question;
        string description;
        string category;
        string imageIpfsHash; // placeholder IPFS CIDs for dev
        string dataIpfsHash;
        uint256 daysToResolution;
    }

    // ─── Entry point ──────────────────────────────────────────────────────────

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        // ── Load deployed addresses ────────────────────────────────────────────
        string memory chain   = _chainName();
        string memory path    = string.concat("deployments/", chain, ".json");
        string memory jsonBlob = vm.readFile(path);

        address marketFactoryAddr = vm.parseJsonAddress(jsonBlob, ".MarketFactory");
        address usdcAddr          = vm.parseJsonAddress(jsonBlob, ".USDC");

        MarketFactory factory = MarketFactory(marketFactoryAddr);
        IERC20 usdc           = IERC20(usdcAddr);

        uint256 creationFee   = factory.creationFee();
        uint256 costPerMarket = INITIAL_LIQUIDITY + creationFee;
        uint256 totalCost     = 10 * costPerMarket;

        console2.log("==============================================");
        console2.log("  FluxMarkets — Seed 10 Prediction Markets");
        console2.log("==============================================");
        console2.log("Chain:          ", chain);
        console2.log("Deployer:       ", deployer);
        console2.log("MarketFactory:  ", marketFactoryAddr);
        console2.log("USDC:           ", usdcAddr);
        console2.log("Creation fee:   ", creationFee);
        console2.log("Cost per market:", costPerMarket);
        console2.log("Total needed:   ", totalCost);
        console2.log("==============================================");

        vm.startBroadcast(deployerKey);

        // ── On local: mint USDC from the mock ─────────────────────────────────
        if (block.chainid == 31337) {
            (bool ok,) = usdcAddr.call(
                abi.encodeWithSignature("mint(address,uint256)", deployer, totalCost * 2)
            );
            require(ok, "CreateTestMarkets: MockUSDC mint failed");
            console2.log("[local] Minted", totalCost * 2, "mock USDC to deployer");
        }

        // ── Approve factory for all USDC needed ───────────────────────────────
        usdc.approve(marketFactoryAddr, type(uint256).max);

        // ── Create markets ────────────────────────────────────────────────────
        MarketSeed[10] memory seeds = _getSeeds();

        for (uint256 i = 0; i < 10; i++) {
            MarketSeed memory s = seeds[i];

            MarketFactory.MarketMetadata memory meta = MarketFactory.MarketMetadata({
                question:        s.question,
                description:     s.description,
                category:        s.category,
                imageIpfsHash:   s.imageIpfsHash,
                dataIpfsHash:    s.dataIpfsHash,
                resolutionTime:  block.timestamp + s.daysToResolution * 1 days,
                creator:         deployer,
                initialLiquidity: INITIAL_LIQUIDITY
            });

            bytes32 conditionId = factory.createMarket(s.questionId, meta, INITIAL_LIQUIDITY);

            console2.log("");
            console2.log(string.concat("  [", vm.toString(i + 1), "/10] ", s.question));
            console2.log("    category:    ", s.category);
            console2.log("    conditionId: ", vm.toString(conditionId));
            console2.log("    resolves in: ", vm.toString(s.daysToResolution), " days");
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("==============================================");
        console2.log("  Done! 10 markets seeded.");
        console2.log("==============================================");
    }

    // ─── Market definitions ───────────────────────────────────────────────────

    /// @dev Returns 10 realistic prediction markets across categories.
    ///      IPFS hashes are placeholder CIDs — replace with real uploads in production.
    function _getSeeds() internal pure returns (MarketSeed[10] memory s) {
        // ── Politics (3) ──────────────────────────────────────────────────────

        s[0] = MarketSeed({
            questionId: keccak256("fluxmarkets:v1:politics:us-crypto-bill-2026"),
            question: "Will the US Congress pass a comprehensive crypto regulatory bill by end of 2026?",
            description:
                "Resolves YES if the US Congress passes and the President signs into law a bill "
                "that establishes a clear federal regulatory framework for digital assets before "
                "2027-01-01 00:00 UTC.",
            category: "politics",
            imageIpfsHash: "QmPolitics1ImageCIDPlaceholderABCDEFGHIJKLMNOPQRST",
            dataIpfsHash:  "QmPolitics1DataCIDPlaceholderUVWXYZ1234567890ABCD",
            daysToResolution: 270
        });

        s[1] = MarketSeed({
            questionId: keccak256("fluxmarkets:v1:politics:eu-mica-enforcement-2026"),
            question: "Will the EU enforce MiCA regulations against at least 3 major exchanges by Q3 2026?",
            description:
                "Resolves YES if the European Securities and Markets Authority (ESMA) or any "
                "national competent authority issues formal enforcement actions under MiCA against "
                "three or more crypto exchanges with >$1B daily volume before 2026-10-01.",
            category: "politics",
            imageIpfsHash: "QmPolitics2ImageCIDPlaceholderABCDEFGHIJKLMNOPQRST",
            dataIpfsHash:  "QmPolitics2DataCIDPlaceholderUVWXYZ1234567890ABCD",
            daysToResolution: 180
        });

        s[2] = MarketSeed({
            questionId: keccak256("fluxmarkets:v1:politics:sec-spot-eth-etf-options-2026"),
            question: "Will the SEC approve options trading on spot Ethereum ETFs by end of 2026?",
            description:
                "Resolves YES if the SEC approves at least one application to list and trade "
                "options on any spot Ethereum ETF before 2027-01-01. Based on official SEC filings.",
            category: "politics",
            imageIpfsHash: "QmPolitics3ImageCIDPlaceholderABCDEFGHIJKLMNOPQRST",
            dataIpfsHash:  "QmPolitics3DataCIDPlaceholderUVWXYZ1234567890ABCD",
            daysToResolution: 240
        });

        // ── Crypto (4) ────────────────────────────────────────────────────────

        s[3] = MarketSeed({
            questionId: keccak256("fluxmarkets:v1:crypto:btc-150k-2026"),
            question: "Will Bitcoin (BTC) reach $150,000 at any point in 2026?",
            description:
                "Resolves YES if the BTC/USD spot price on Coinbase or Binance closes above "
                "$150,000 on any UTC day before 2027-01-01. Uses median of top-3 exchange prices.",
            category: "crypto",
            imageIpfsHash: "QmCrypto1ImageCIDPlaceholderABCDEFGHIJKLMNOPQRSTUV",
            dataIpfsHash:  "QmCrypto1DataCIDPlaceholderUVWXYZ1234567890ABCDEF",
            daysToResolution: 280
        });

        s[4] = MarketSeed({
            questionId: keccak256("fluxmarkets:v1:crypto:eth-5k-2026"),
            question: "Will Ethereum (ETH) reach $5,000 before December 31, 2026?",
            description:
                "Resolves YES if the ETH/USD spot price on Coinbase Pro closes above $5,000 "
                "on any UTC day before 2026-12-31 23:59 UTC. "
                "Source: CoinGecko 24h VWAP at close.",
            category: "crypto",
            imageIpfsHash: "QmCrypto2ImageCIDPlaceholderABCDEFGHIJKLMNOPQRSTUV",
            dataIpfsHash:  "QmCrypto2DataCIDPlaceholderUVWXYZ1234567890ABCDEF",
            daysToResolution: 252
        });

        s[5] = MarketSeed({
            questionId: keccak256("fluxmarkets:v1:crypto:pol-outperform-eth-2026"),
            question: "Will Polygon POL outperform ETH in percentage returns from April to October 2026?",
            description:
                "Resolves YES if POL/USD percentage return from 2026-04-01 00:00 UTC to "
                "2026-10-01 00:00 UTC exceeds ETH/USD percentage return over the same period. "
                "Opening prices sourced from CoinGecko daily close on the respective dates.",
            category: "crypto",
            imageIpfsHash: "QmCrypto3ImageCIDPlaceholderABCDEFGHIJKLMNOPQRSTUV",
            dataIpfsHash:  "QmCrypto3DataCIDPlaceholderUVWXYZ1234567890ABCDEF",
            daysToResolution: 189
        });

        s[6] = MarketSeed({
            questionId: keccak256("fluxmarkets:v1:crypto:total-market-cap-3t-2026"),
            question: "Will total crypto market cap exceed $3 trillion in 2026?",
            description:
                "Resolves YES if the total cryptocurrency market capitalization as reported by "
                "CoinGecko exceeds $3,000,000,000,000 USD on any day before 2027-01-01.",
            category: "crypto",
            imageIpfsHash: "QmCrypto4ImageCIDPlaceholderABCDEFGHIJKLMNOPQRSTUV",
            dataIpfsHash:  "QmCrypto4DataCIDPlaceholderUVWXYZ1234567890ABCDEF",
            daysToResolution: 300
        });

        // ── Sports (2) ────────────────────────────────────────────────────────

        s[7] = MarketSeed({
            questionId: keccak256("fluxmarkets:v1:sports:argentina-world-cup-2026"),
            question: "Will Argentina win the 2026 FIFA World Cup?",
            description:
                "Resolves YES if the Argentina national football team is declared the winner "
                "of the 2026 FIFA World Cup (hosted in USA, Canada, Mexico). "
                "Resolution based on official FIFA announcement.",
            category: "sports",
            imageIpfsHash: "QmSports1ImageCIDPlaceholderABCDEFGHIJKLMNOPQRSTUV",
            dataIpfsHash:  "QmSports1DataCIDPlaceholderUVWXYZ1234567890ABCDEF",
            daysToResolution: 120
        });

        s[8] = MarketSeed({
            questionId: keccak256("fluxmarkets:v1:sports:hamilton-ferrari-win-2026"),
            question: "Will Lewis Hamilton win at least one Formula 1 race for Ferrari in the 2026 season?",
            description:
                "Resolves YES if Lewis Hamilton, driving for Scuderia Ferrari, finishes P1 in "
                "any FIA Formula One World Championship race during the 2026 season "
                "(from 2026 season opener through final race). Based on official FIA results.",
            category: "sports",
            imageIpfsHash: "QmSports2ImageCIDPlaceholderABCDEFGHIJKLMNOPQRSTUV",
            dataIpfsHash:  "QmSports2DataCIDPlaceholderUVWXYZ1234567890ABCDEF",
            daysToResolution: 210
        });

        // ── Tech / Finance (2) ────────────────────────────────────────────────

        s[9] = MarketSeed({
            questionId: keccak256("fluxmarkets:v1:tech:fed-rate-cuts-3-2026"),
            question: "Will the US Federal Reserve cut interest rates 3 or more times in 2026?",
            description:
                "Resolves YES if the Federal Open Market Committee (FOMC) reduces the federal "
                "funds target rate at 3 or more separate meetings during calendar year 2026 "
                "(Jan 2026 – Dec 2026). Each 25bps+ reduction at a single meeting counts as one cut. "
                "Source: official FOMC press releases on federalreserve.gov.",
            category: "finance",
            imageIpfsHash: "QmFinance1ImageCIDPlaceholderABCDEFGHIJKLMNOPQRST",
            dataIpfsHash:  "QmFinance1DataCIDPlaceholderUVWXYZ1234567890ABCDE",
            daysToResolution: 282
        });
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _chainName() internal view returns (string memory) {
        uint256 id = block.chainid;
        if (id == 31337) return "localhost";
        if (id == 80002) return "polygon_amoy";
        if (id == 137)   return "polygon";
        return vm.toString(id);
    }
}
