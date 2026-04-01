import {
  pgTable,
  text,
  boolean,
  numeric,
  timestamp,
  integer,
  index,
  pgEnum,
} from 'drizzle-orm/pg-core'

export const outcomeEnum = pgEnum('outcome', ['UNRESOLVED', 'YES', 'NO', 'INVALID'])

export const markets = pgTable(
  'markets',
  {
    id: text('id').primaryKey(),
    creator: text('creator').notNull(),
    question: text('question').notNull(),
    description: text('description').notNull().default(''),
    endTime: timestamp('end_time').notNull(),
    resolutionTime: timestamp('resolution_time').notNull(),
    outcome: outcomeEnum('outcome').notNull().default('UNRESOLVED'),
    yesShares: numeric('yes_shares', { precision: 78, scale: 18 }).notNull().default('0'),
    noShares: numeric('no_shares', { precision: 78, scale: 18 }).notNull().default('0'),
    totalLiquidity: numeric('total_liquidity', { precision: 78, scale: 18 }).notNull().default('0'),
    resolved: boolean('resolved').notNull().default(false),
    chainId: integer('chain_id').notNull().default(31337),
    txHash: text('tx_hash'),
    blockNumber: integer('block_number'),
    createdAt: timestamp('created_at').notNull().defaultNow(),
    updatedAt: timestamp('updated_at').notNull().defaultNow(),
  },
  (t) => ({
    creatorIdx: index('markets_creator_idx').on(t.creator),
    resolvedIdx: index('markets_resolved_idx').on(t.resolved),
    endTimeIdx: index('markets_end_time_idx').on(t.endTime),
  }),
)

export const trades = pgTable(
  'trades',
  {
    id: text('id').primaryKey(),           // txHash-logIndex
    marketId: text('market_id').notNull().references(() => markets.id),
    trader: text('trader').notNull(),
    isYes: boolean('is_yes').notNull(),
    amountIn: numeric('amount_in', { precision: 78, scale: 18 }).notNull(),
    sharesOut: numeric('shares_out', { precision: 78, scale: 18 }).notNull(),
    txHash: text('tx_hash').notNull(),
    blockNumber: integer('block_number').notNull(),
    timestamp: timestamp('timestamp').notNull(),
  },
  (t) => ({
    marketIdx: index('trades_market_idx').on(t.marketId),
    traderIdx: index('trades_trader_idx').on(t.trader),
    timestampIdx: index('trades_timestamp_idx').on(t.timestamp),
  }),
)

export const positions = pgTable(
  'positions',
  {
    id: text('id').primaryKey(),           // marketId-trader
    marketId: text('market_id').notNull().references(() => markets.id),
    trader: text('trader').notNull(),
    yesShares: numeric('yes_shares', { precision: 78, scale: 18 }).notNull().default('0'),
    noShares: numeric('no_shares', { precision: 78, scale: 18 }).notNull().default('0'),
    totalInvested: numeric('total_invested', { precision: 78, scale: 18 }).notNull().default('0'),
    realizedPnl: numeric('realized_pnl', { precision: 78, scale: 18 }).notNull().default('0'),
    updatedAt: timestamp('updated_at').notNull().defaultNow(),
  },
  (t) => ({
    marketIdx: index('positions_market_idx').on(t.marketId),
    traderIdx: index('positions_trader_idx').on(t.trader),
  }),
)
