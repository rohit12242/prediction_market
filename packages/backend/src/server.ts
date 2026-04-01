import express from 'express'
import { createYoga } from 'graphql-yoga'
import { schema } from './graphql/schema.js'
import { createContext } from './graphql/context.js'
import { authMiddleware } from './middleware/auth.js'
import { logger } from './lib/logger.js'

export function createServer() {
  const app = express()

  app.use(express.json())

  // Health check
  app.get('/health', (_req, res) => {
    res.json({ status: 'ok', timestamp: new Date().toISOString() })
  })

  // GraphQL via Yoga (supports HTTP + WS)
  const yoga = createYoga({
    schema,
    context: createContext,
    graphiql: process.env.NODE_ENV !== 'production',
    logging: {
      debug: (...args) => logger.debug(args),
      info: (...args) => logger.info(args),
      warn: (...args) => logger.warn(args),
      error: (...args) => logger.error(args),
    },
  })

  app.use('/graphql', authMiddleware, yoga)

  return app
}
