import { createServer } from './server.js'
import { logger } from './lib/logger.js'
import { db } from './db/client.js'
import { redis } from './lib/redis.js'

const PORT = Number(process.env.PORT ?? 4000)

async function main() {
  await db.$client.connect()
  logger.info('PostgreSQL connected')

  await redis.connect()
  logger.info('Redis connected')

  const server = createServer()

  server.listen(PORT, () => {
    logger.info({ port: PORT }, 'FluxMarkets backend listening')
  })

  const shutdown = async () => {
    logger.info('Shutting down...')
    await redis.quit()
    await db.$client.end()
    process.exit(0)
  }

  process.on('SIGTERM', shutdown)
  process.on('SIGINT', shutdown)
}

main().catch((err) => {
  logger.error(err, 'Fatal startup error')
  process.exit(1)
})
