CREATE TYPE outcome AS ENUM ('UNRESOLVED', 'YES', 'NO', 'INVALID');

CREATE TABLE markets (
  id TEXT PRIMARY KEY,
  creator TEXT NOT NULL,
  question TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  end_time TIMESTAMPTZ NOT NULL,
  resolution_time TIMESTAMPTZ NOT NULL,
  outcome outcome NOT NULL DEFAULT 'UNRESOLVED',
  yes_shares NUMERIC(78, 18) NOT NULL DEFAULT 0,
  no_shares NUMERIC(78, 18) NOT NULL DEFAULT 0,
  total_liquidity NUMERIC(78, 18) NOT NULL DEFAULT 0,
  resolved BOOLEAN NOT NULL DEFAULT false,
  chain_id INTEGER NOT NULL DEFAULT 31337,
  tx_hash TEXT,
  block_number INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX markets_creator_idx ON markets(creator);
CREATE INDEX markets_resolved_idx ON markets(resolved);
CREATE INDEX markets_end_time_idx ON markets(end_time);

CREATE TABLE trades (
  id TEXT PRIMARY KEY,
  market_id TEXT NOT NULL REFERENCES markets(id),
  trader TEXT NOT NULL,
  is_yes BOOLEAN NOT NULL,
  amount_in NUMERIC(78, 18) NOT NULL,
  shares_out NUMERIC(78, 18) NOT NULL,
  tx_hash TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  timestamp TIMESTAMPTZ NOT NULL
);

CREATE INDEX trades_market_idx ON trades(market_id);
CREATE INDEX trades_trader_idx ON trades(trader);
CREATE INDEX trades_timestamp_idx ON trades(timestamp);

CREATE TABLE positions (
  id TEXT PRIMARY KEY,
  market_id TEXT NOT NULL REFERENCES markets(id),
  trader TEXT NOT NULL,
  yes_shares NUMERIC(78, 18) NOT NULL DEFAULT 0,
  no_shares NUMERIC(78, 18) NOT NULL DEFAULT 0,
  total_invested NUMERIC(78, 18) NOT NULL DEFAULT 0,
  realized_pnl NUMERIC(78, 18) NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX positions_market_idx ON positions(market_id);
CREATE INDEX positions_trader_idx ON positions(trader);
