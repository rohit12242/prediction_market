import type { Request } from 'express'
import { db } from '../db/client.js'
import { redis } from '../lib/redis.js'

export interface Context {
  db: typeof db
  redis: typeof redis
  user: { address: string } | null
  req: Request
}

export function createContext({ request }: { request: Request }): Context {
  const user = (request as any).user ?? null
  return { db, redis, user, req: request }
}
