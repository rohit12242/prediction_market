import { MarketDeployed } from '../generated/MarketFactory/MarketFactory'
import { Market } from '../generated/schema'
import {
  ZERO_BD, ZERO_BI, HALF_BD,
  getOrCreateProtocol, getOrCreateUser, ONE_BI
} from './helpers'

export function handleMarketDeployed(event: MarketDeployed): void {
  let conditionId = event.params.conditionId.toHexString()

  // Market entity may already exist from PredictionMarket.MarketCreated
  // if both events fire in the same block. Upsert pattern: load or create.
  let market = Market.load(conditionId)
  if (market == null) {
    market = new Market(conditionId)
    market.question        = event.params.question
    market.description     = ''
    market.ipfsHash        = ''
    market.yesReserve      = ZERO_BD
    market.noReserve       = ZERO_BD
    market.liquidity       = ZERO_BD
    market.bestBid         = ZERO_BD
    market.bestAsk         = ZERO_BD
    market.probability     = HALF_BD
    market.lastTradePrice  = HALF_BD
    market.totalVolume     = ZERO_BD
    market.fpmmVolume      = ZERO_BD
    market.clobVolume      = ZERO_BD
    market.tradeCount      = ZERO_BI
    market.orderCount      = ZERO_BI
    market.uniqueTraderCount = ZERO_BI
    market.status          = 'Active'
    market.payouts         = []
    market.createdAt       = event.block.timestamp
    market.createdAtBlock  = event.block.number
    market.resolutionTime  = event.params.resolutionTime
    market.creator         = event.params.creator
  }

  // Always update fields that MarketFactory provides
  market.category     = _detectCategory(event.params.question)
  market.dataIpfsHash = event.params.dataIpfsHash

  market.save()

  // Update protocol & user
  let protocol = getOrCreateProtocol()
  protocol.totalMarkets  = protocol.totalMarkets.plus(ONE_BI)
  protocol.activeMarkets = protocol.activeMarkets.plus(ONE_BI)
  protocol.updatedAt     = event.block.timestamp
  protocol.save()

  let user = getOrCreateUser(event.params.creator, event.block.timestamp)
  user.marketsCreated = user.marketsCreated.plus(ONE_BI)
  user.lastActiveAt   = event.block.timestamp
  user.save()
}

// Naive category detection from IPFS metadata question prefix.
// In production this would be set from the metadata struct directly.
function _detectCategory(question: string): string {
  let q = question.toLowerCase()
  if (q.indexOf('btc') >= 0 || q.indexOf('eth') >= 0 || q.indexOf('crypto') >= 0
      || q.indexOf('bitcoin') >= 0 || q.indexOf('ethereum') >= 0
      || q.indexOf('defi') >= 0 || q.indexOf('polygon') >= 0) {
    return 'crypto'
  }
  if (q.indexOf('elect') >= 0 || q.indexOf('president') >= 0
      || q.indexOf('congress') >= 0 || q.indexOf('vote') >= 0
      || q.indexOf('political') >= 0 || q.indexOf('government') >= 0) {
    return 'politics'
  }
  if (q.indexOf('world cup') >= 0 || q.indexOf('nba') >= 0
      || q.indexOf('nfl') >= 0 || q.indexOf('f1') >= 0
      || q.indexOf('formula') >= 0 || q.indexOf('soccer') >= 0
      || q.indexOf('football') >= 0 || q.indexOf('hamilton') >= 0) {
    return 'sports'
  }
  if (q.indexOf('fed') >= 0 || q.indexOf('rate') >= 0
      || q.indexOf('inflation') >= 0 || q.indexOf('gdp') >= 0) {
    return 'finance'
  }
  return 'other'
}
