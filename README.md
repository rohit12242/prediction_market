# FluxMarkets

A decentralized prediction market platform built on EVM-compatible blockchains.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        FluxMarkets Monorepo                     │
├──────────────┬──────────────┬──────────────┬────────────────────┤
│  contracts   │   subgraph   │   backend    │     frontend       │
│  (Foundry)   │  (The Graph) │  (Node/GQL)  │   (Next.js 14)     │
├──────────────┴──────────────┴──────────────┴────────────────────┤
│              pnpm workspaces + Turborepo pipeline               │
└─────────────────────────────────────────────────────────────────┘
```

### Packages

| Package | Stack | Purpose |
|---|---|---|
| `packages/contracts` | Solidity · Foundry | Smart contracts — markets, oracle, settlement |
| `packages/subgraph` | AssemblyScript · The Graph | Real-time on-chain event indexing |
| `packages/backend` | Node.js · TypeScript · GraphQL · Postgres · Redis | REST + GraphQL API, auth, order book |
| `packages/frontend` | Next.js 14 · Tailwind CSS · wagmi v2 · viem | Trader-facing UI |

### Data Flow

```
User Browser (frontend)
    │  wagmi / viem
    ▼
Smart Contracts ──── events ────► The Graph (subgraph)
                                       │ GraphQL
                                       ▼
                               Backend API ◄──── Postgres / Redis
                                       │ GraphQL / REST
                                       ▼
                               Frontend (SSR + CSR)
```

## Quick Start

### Prerequisites

- Node.js ≥ 20
- pnpm ≥ 9 (`npm i -g pnpm`)
- Docker & Docker Compose
- Foundry (`curl -L https://foundry.paradigm.xyz | bash && foundryup`)

### 1. Install dependencies

```bash
pnpm install
```

### 2. Configure environment

```bash
cp .env.example .env
# Edit .env with your values
```

### 3. Start local infrastructure

```bash
pnpm docker:up
# Starts: Postgres, Redis, Graph Node, IPFS
```

### 4. Deploy contracts (local Anvil node)

```bash
# In a separate terminal
anvil

# Deploy
cd packages/contracts
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
```

### 5. Deploy subgraph

```bash
cd packages/subgraph
pnpm codegen
pnpm build
pnpm deploy:local
```

### 6. Start backend + frontend

```bash
# From root
pnpm dev
```

- Frontend: http://localhost:3000
- Backend GraphQL: http://localhost:4000/graphql
- Subgraph: http://localhost:8000/subgraphs/name/fluxmarkets/core

## Build Pipeline (Turborepo)

```
contracts:build
     └─► subgraph:codegen ─► subgraph:build
backend:build ─────────────────────────────► frontend:build
```

All tasks are cached by Turborepo — only changed packages rebuild.

## Repository Structure

```
prediction_market/
├── packages/
│   ├── contracts/          # Solidity smart contracts
│   │   ├── src/            # Contract source files
│   │   ├── test/           # Foundry tests
│   │   └── script/         # Deployment scripts
│   ├── subgraph/           # The Graph indexer
│   │   ├── src/            # AssemblyScript mappings
│   │   ├── schema.graphql  # GraphQL schema
│   │   └── subgraph.yaml   # Subgraph manifest
│   ├── backend/            # API server
│   │   ├── src/
│   │   │   ├── graphql/    # Resolvers & schema
│   │   │   ├── db/         # Drizzle ORM + migrations
│   │   │   ├── services/   # Business logic
│   │   │   └── middleware/ # Auth, rate-limit, etc.
│   │   └── db/             # SQL init scripts
│   └── frontend/           # Next.js app
│       ├── app/            # App Router pages
│       ├── components/     # Reusable UI
│       ├── lib/            # wagmi config, utils
│       └── hooks/          # Custom React hooks
├── turbo.json              # Build pipeline
├── docker-compose.yml      # Local dev infra
└── .env.example            # Environment template
```

## Smart Contract Architecture

```
PredictionMarket.sol        # Core market factory + resolution
  └── Market.sol            # Individual market instance
OracleResolver.sol          # Outcome oracle (UMA / Chainlink)
ConditionalToken.sol        # ERC-1155 outcome tokens
LiquidityPool.sol           # AMM liquidity (CPMM)
```

## Contributing

1. Branch from `main` → `feat/<description>` or `fix/<description>`
2. `pnpm lint && pnpm typecheck && pnpm test` must pass
3. Open a PR — CI runs the full Turborepo pipeline

## License

MIT
