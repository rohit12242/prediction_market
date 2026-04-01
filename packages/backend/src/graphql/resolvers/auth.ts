import jwt from 'jsonwebtoken'
import { ethers } from 'ethers'
import type { Context } from '../context.js'

const JWT_SECRET = process.env.JWT_SECRET ?? 'dev-secret-change-me'

export const authResolvers = {
  Mutation: {
    async nonce(_: unknown, args: { address: string }, ctx: Context) {
      const nonce = Math.floor(Math.random() * 1_000_000).toString()
      await ctx.redis.set(`nonce:${args.address.toLowerCase()}`, nonce, 'EX', 300)
      return nonce
    },

    async login(
      _: unknown,
      args: { address: string; signature: string },
      ctx: Context,
    ) {
      const address = args.address.toLowerCase()
      const nonce = await ctx.redis.get(`nonce:${address}`)
      if (!nonce) throw new Error('Nonce expired or not found')

      const message = `Sign in to FluxMarkets\nNonce: ${nonce}`
      const recovered = ethers.verifyMessage(message, args.signature).toLowerCase()
      if (recovered !== address) throw new Error('Invalid signature')

      await ctx.redis.del(`nonce:${address}`)

      const token = jwt.sign({ address }, JWT_SECRET, { expiresIn: '7d' })
      return { token, address }
    },
  },
}
