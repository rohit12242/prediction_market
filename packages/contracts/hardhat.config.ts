/**
 * hardhat.config.ts
 *
 * Hardhat is used as a FALLBACK for Polygonscan contract verification when
 * `forge --verify` fails (e.g. rate-limit, complex constructor args, proxy patterns).
 *
 * Primary build / test toolchain: Foundry (forge).
 *
 * Usage:
 *   npx hardhat verify --network polygon    <address> [constructor args...]
 *   npx hardhat verify --network polygonAmoy <address> [constructor args...]
 *
 *   Or via Makefile:
 *     make verify NETWORK=polygon
 *     make verify NETWORK=polygon_amoy
 *
 * Required env vars:
 *   POLYGONSCAN_API_KEY  — from https://polygonscan.com/myapikey
 *   RPC_URL_POLYGON      — Polygon mainnet RPC (Alchemy / Infura / public)
 *   RPC_URL_POLYGON_AMOY — Polygon Amoy testnet RPC (optional; falls back to public)
 *   PRIVATE_KEY          — deployer private key (0x-prefixed)
 */

import { HardhatUserConfig } from "hardhat/config"
import "@nomicfoundation/hardhat-verify"

// Load env — gracefully skip if not present (CI may inject vars directly)
try { require("dotenv").config({ path: "../../.env" }) } catch {}
try { require("dotenv").config({ path: ".env" })        } catch {}

const PRIVATE_KEY      = process.env.PRIVATE_KEY          ?? "0x" + "0".repeat(64)
const POLYGONSCAN_KEY  = process.env.POLYGONSCAN_API_KEY  ?? ""
const RPC_POLYGON      = process.env.RPC_URL_POLYGON       ?? "https://polygon-rpc.com"
const RPC_AMOY         = process.env.RPC_URL_POLYGON_AMOY  ?? "https://rpc-amoy.polygon.technology"

const config: HardhatUserConfig = {
  // ── Solidity ────────────────────────────────────────────────────────────────
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
    },
  },

  // ── Networks ─────────────────────────────────────────────────────────────────
  networks: {
    // Local Anvil / Hardhat node
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 31337,
      accounts: [PRIVATE_KEY],
    },

    // Polygon Mainnet
    polygon: {
      url: RPC_POLYGON,
      chainId: 137,
      accounts: [PRIVATE_KEY],
      gasPrice: "auto",
    },

    // Polygon Amoy Testnet (replaces Mumbai)
    polygonAmoy: {
      url: RPC_AMOY,
      chainId: 80002,
      accounts: [PRIVATE_KEY],
      gasPrice: "auto",
    },
  },

  // ── Etherscan / Polygonscan verification ──────────────────────────────────────
  etherscan: {
    apiKey: {
      polygon:     POLYGONSCAN_KEY,
      polygonAmoy: POLYGONSCAN_KEY,
    },
    customChains: [
      {
        network: "polygonAmoy",
        chainId: 80002,
        urls: {
          apiURL:     "https://api-amoy.polygonscan.com/api",
          browserURL: "https://amoy.polygonscan.com",
        },
      },
    ],
  },

  // ── Source paths (points at Foundry src for recompilation if needed) ─────────
  paths: {
    sources:   "./src",
    tests:     "./test",
    cache:     "./cache-hardhat",
    artifacts: "./artifacts",
  },
}

export default config
