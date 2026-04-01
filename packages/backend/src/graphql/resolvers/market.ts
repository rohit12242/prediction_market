import type { Context } from '../context.js'
import { markets, trades, positions } from '../../db/schema.js'
import { eq, desc, ilike, and } from 'drizzle-orm'

// Compute implied probability prices from share reserves (CPMM)
function computePrices(yesShares: string, noShares: string) {
  const yes = parseFloat(yesShares)
  const no = parseFloat(noShares)
  const total = yes + no
  if (total === 0) return { yesPrice: 0.5, noPrice: 0.5 }
  return {
    yesPrice: no / total,
    noPrice: yes / total,
  }
}

export const marketResolvers = {
  Query: {
    async markets(
      _: unknown,
      args: { limit?: number; offset?: number; resolved?: boolean; search?: string },
      ctx: Context,
    ) {
      const { limit = 20, offset = 0, resolved, search } = args
      const conditions = []
      if (resolved !== undefined) conditions.push(eq(markets.resolved, resolved))
      if (search) conditions.push(ilike(markets.question, `%${search}%`))

      return ctx.db
        .select()
        .from(markets)
        .where(conditions.length ? and(...conditions) : undefined)
        .orderBy(desc(markets.createdAt))
        .limit(limit)
        .offset(offset)
    },

    async market(_: unknown, args: { id: string }, ctx: Context) {
      const [market] = await ctx.db
        .select()
        .from(markets)
        .where(eq(markets.id, args.id))
        .limit(1)
      return market ?? null
    },

    async trades(
      _: unknown,
      args: { marketId?: string; trader?: string; limit?: number; offset?: number },
      ctx: Context,
    ) {
      const { marketId, trader, limit = 50, offset = 0 } = args
      const conditions = []
      if (marketId) conditions.push(eq(trades.marketId, marketId))
      if (trader) conditions.push(eq(trades.trader, trader))

      return ctx.db
        .select()
        .from(trades)
        .where(conditions.length ? and(...conditions) : undefined)
        .orderBy(desc(trades.timestamp))
        .limit(limit)
        .offset(offset)
    },

    async positions(_: unknown, args: { trader: string }, ctx: Context) {
      return ctx.db
        .select()
        .from(positions)
        .where(eq(positions.trader, args.trader.toLowerCase()))
    },

    async me(_: unknown, __: unknown, ctx: Context) {
      if (!ctx.user) return null
      return { address: ctx.user.address }
    },
  },

  // Field resolvers for Market type
  Market: {
    yesPrice(parent: { yesShares: string; noShares: string }) {
      return computePrices(parent.yesShares, parent.noShares).yesPrice
    },

    noPrice(parent: { yesShares: string; noShares: string }) {
      return computePrices(parent.yesShares, parent.noShares).noPrice
    },

    async trades(
      parent: { id: string },
      args: { limit?: number; offset?: number },
      ctx: Context,
    ) {
      return ctx.db
        .select()
        .from(trades)
        .where(eq(trades.marketId, parent.id))
        .orderBy(desc(trades.timestamp))
        .limit(args.limit ?? 50)
        .offset(args.offset ?? 0)
    },
  },

  // Field resolvers for User type
  User: {
    async positions(parent: { address: string }, _: unknown, ctx: Context) {
      return ctx.db
        .select()
        .from(positions)
        .where(eq(positions.trader, parent.address.toLowerCase()))
    },

    async trades(
      parent: { address: string },
      args: { limit?: number; offset?: number },
      ctx: Context,
    ) {
      return ctx.db
        .select()
        .from(trades)
        .where(eq(trades.trader, parent.address.toLowerCase()))
        .orderBy(desc(trades.timestamp))
        .limit(args.limit ?? 50)
        .offset(args.offset ?? 0)
    },
  },
}
