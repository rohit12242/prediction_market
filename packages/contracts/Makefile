# ──────────────────────────────────────────────────────────────────────────────
#  FluxMarkets Contracts — Makefile
#
#  Usage:
#    make test                    # run full Foundry test suite
#    make deploy-local            # spin up Anvil, deploy all contracts, seed 10 markets
#    make deploy-amoy             # deploy to Polygon Amoy testnet + verify
#    make deploy-polygon          # deploy to Polygon mainnet  + verify  (asks confirmation)
#    make verify NETWORK=polygon  # fallback verification via Hardhat
#    make coverage                # generate lcov coverage report
#    make fmt                     # format Solidity
#    make gas                     # gas usage report
#    make clean                   # clean build artifacts
#
#  Required env vars (copy from ../../.env.example):
#    PRIVATE_KEY          deployer private key (0x-prefixed)
#    POLYGONSCAN_API_KEY  from https://polygonscan.com/apis
#    RPC_URL_POLYGON      e.g. https://polygon-mainnet.g.alchemy.com/v2/<key>
#    RPC_URL_POLYGON_AMOY e.g. https://polygon-amoy.g.alchemy.com/v2/<key>  (optional — falls back to public)
# ──────────────────────────────────────────────────────────────────────────────

# Load .env if present (never override existing shell exports)
-include .env
-include ../../.env
export

# Detect OS for sed compatibility
UNAME := $(shell uname)

# ─── Default target ───────────────────────────────────────────────────────────
.DEFAULT_GOAL := help

.PHONY: help build test test-fork coverage gas fmt lint clean \
        anvil deploy-local seed-local \
        deploy-amoy seed-amoy \
        deploy-polygon seed-polygon \
        verify verify-polygon verify-amoy \
        install snapshot

help:  ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ─── Build & test ─────────────────────────────────────────────────────────────

install:  ## Install Foundry dependencies
	forge install

build:  ## Compile all contracts
	forge build

test:  ## Run full Foundry test suite (verbose)
	forge test -vvv

test-fork:  ## Run tests against a forked Polygon mainnet
	forge test -vvv --fork-url $(RPC_URL_POLYGON) --fork-block-number latest

coverage:  ## Generate lcov coverage report (open coverage/index.html)
	forge coverage --report lcov
	@command -v genhtml >/dev/null 2>&1 && \
		genhtml lcov.info --output-directory coverage --quiet && \
		echo "Coverage report: coverage/index.html" || \
		echo "Install lcov for HTML report: brew install lcov"

gas:  ## Print gas usage table
	forge test --gas-report

snapshot:  ## Write .gas-snapshot (CI baseline)
	forge snapshot

fmt:  ## Format Solidity with forge fmt
	forge fmt

lint:  ## Check formatting without modifying files
	forge fmt --check

clean:  ## Remove build artifacts and cache
	forge clean
	rm -rf cache out

# ─── Local Anvil deployment ───────────────────────────────────────────────────

anvil:  ## Start a local Anvil node (chain-id 31337)
	anvil --chain-id 31337 --accounts 10 --balance 10000

deploy-local:  ## Deploy all contracts to local Anvil and seed 10 test markets
	@echo "──────────────────────────────────────────────"
	@echo "  Deploying to local Anvil (chain 31337)"
	@echo "──────────────────────────────────────────────"
	forge script script/Deploy.s.sol \
		--rpc-url localhost \
		--broadcast \
		-vvvv
	@echo ""
	@echo "  Seeding 10 test markets..."
	forge script script/CreateTestMarkets.s.sol \
		--rpc-url localhost \
		--broadcast \
		-vvvv
	@echo "──────────────────────────────────────────────"
	@echo "  Done! Deployed addresses: deployments/localhost.json"
	@echo "──────────────────────────────────────────────"

seed-local:  ## Seed 10 test markets on local Anvil (after deploy-local)
	forge script script/CreateTestMarkets.s.sol \
		--rpc-url localhost \
		--broadcast \
		-vvvv

# ─── Polygon Amoy (testnet) ───────────────────────────────────────────────────

AMOY_RPC ?= $(if $(RPC_URL_POLYGON_AMOY),$(RPC_URL_POLYGON_AMOY),https://rpc-amoy.polygon.technology)

deploy-amoy:  ## Deploy to Polygon Amoy testnet and verify contracts
	@echo "──────────────────────────────────────────────"
	@echo "  Deploying to Polygon Amoy testnet"
	@echo "──────────────────────────────────────────────"
	forge script script/Deploy.s.sol \
		--rpc-url $(AMOY_RPC) \
		--chain-id 80002 \
		--broadcast \
		--verify \
		--etherscan-api-key $(POLYGONSCAN_API_KEY) \
		--verifier-url https://api-amoy.polygonscan.com/api \
		--delay 5 \
		-vvvv
	@echo "Saved deployments to: deployments/polygon_amoy.json"

seed-amoy:  ## Seed 10 test markets on Polygon Amoy
	forge script script/CreateTestMarkets.s.sol \
		--rpc-url $(AMOY_RPC) \
		--chain-id 80002 \
		--broadcast \
		-vvvv

# ─── Polygon Mainnet ──────────────────────────────────────────────────────────

POLYGON_RPC ?= $(if $(RPC_URL_POLYGON),$(RPC_URL_POLYGON),https://polygon-rpc.com)

deploy-polygon:  ## ⚠️  Deploy to Polygon MAINNET (requires confirmation)
	@echo ""
	@echo "  ╔═══════════════════════════════════════╗"
	@echo "  ║  ⚠️   POLYGON MAINNET DEPLOYMENT  ⚠️   ║"
	@echo "  ║  This will broadcast real transactions ║"
	@echo "  ║  Press Ctrl+C within 5s to abort       ║"
	@echo "  ╚═══════════════════════════════════════╝"
	@sleep 5
	forge script script/Deploy.s.sol \
		--rpc-url $(POLYGON_RPC) \
		--chain-id 137 \
		--broadcast \
		--verify \
		--etherscan-api-key $(POLYGONSCAN_API_KEY) \
		--verifier-url https://api.polygonscan.com/api \
		--delay 10 \
		-vvvv
	@echo "Saved deployments to: deployments/polygon.json"

seed-polygon:  ## Seed 10 test markets on Polygon mainnet
	@echo "Seeding markets on Polygon mainnet..."
	forge script script/CreateTestMarkets.s.sol \
		--rpc-url $(POLYGON_RPC) \
		--chain-id 137 \
		--broadcast \
		-vvvv

# ─── Contract verification (Hardhat fallback) ─────────────────────────────────
#  Use this if forge --verify fails (rate limits, constructor arg encoding, etc.)
#  Requires: deployments/<NETWORK>.json to exist after a successful deployment.

NETWORK ?= polygon  # override with: make verify NETWORK=polygon_amoy

verify:  ## Verify all contracts via Hardhat (NETWORK=polygon|polygon_amoy)
	@test -f deployments/$(NETWORK).json || \
		(echo "ERROR: deployments/$(NETWORK).json not found. Run deploy-$(NETWORK) first." && exit 1)
	@echo "──────────────────────────────────────────────"
	@echo "  Verifying contracts on $(NETWORK)"
	@echo "──────────────────────────────────────────────"
	$(eval CT  := $(shell node -e "console.log(require('./deployments/$(NETWORK).json').ConditionalTokens)"))
	$(eval FF  := $(shell node -e "console.log(require('./deployments/$(NETWORK).json').FPMMFactory)"))
	$(eval OA  := $(shell node -e "console.log(require('./deployments/$(NETWORK).json').UMAOracleAdapter)"))
	$(eval PM  := $(shell node -e "console.log(require('./deployments/$(NETWORK).json').PredictionMarket)"))
	$(eval MF  := $(shell node -e "console.log(require('./deployments/$(NETWORK).json').MarketFactory)"))
	$(eval USDC := $(shell node -e "console.log(require('./deployments/$(NETWORK).json').USDC)"))
	@echo "  ConditionalTokens : $(CT)"
	@echo "  FPMMFactory       : $(FF)"
	@echo "  UMAOracleAdapter  : $(OA)"
	@echo "  PredictionMarket  : $(PM)"
	@echo "  MarketFactory     : $(MF)"
	@echo ""
	npx hardhat verify --network $(NETWORK) $(CT)
	npx hardhat verify --network $(NETWORK) $(FF)
	npx hardhat verify --network $(NETWORK) $(OA) \
		"$(if $(filter polygon,$(NETWORK)),0x5953f2538F613E05bAED8A5AeFa8e6622467AD3D,0x5953f2538F613E05bAED8A5AeFa8e6622467AD3D)" \
		"$(USDC)" \
		"$(CT)" \
		"$(shell cast wallet address $$PRIVATE_KEY)"
	npx hardhat verify --network $(NETWORK) $(PM) \
		"$(USDC)" "$(CT)" "$(FF)" "$(OA)" \
		"$(shell cast wallet address $$PRIVATE_KEY)" \
		"$(shell cast wallet address $$PRIVATE_KEY)"
	npx hardhat verify --network $(NETWORK) $(MF) \
		"$(PM)" "$(USDC)" \
		"$(shell cast wallet address $$PRIVATE_KEY)"
	@echo "──────────────────────────────────────────────"
	@echo "  All contracts verified on $(NETWORK)!"
	@echo "──────────────────────────────────────────────"

verify-polygon:  ## Verify on Polygon mainnet via Hardhat
	$(MAKE) verify NETWORK=polygon

verify-amoy:  ## Verify on Polygon Amoy via Hardhat
	$(MAKE) verify NETWORK=polygon_amoy
