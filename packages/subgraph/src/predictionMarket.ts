import { Address, Bytes } from '@graphprotocol/graph-ts'
import {
  MarketCreated, LiquidityAdded, LiquidityRemoved,
  OutcomeBought, OutcomeSold, MarketResolved,
  MarketCancelled, PositionsRedeemed
} from '../generated/PredictionMarket/PredictionMarket'
import { Market, Trade, LiquidityEvent, CLOBMarketLink } from '../generated/schema'
import {
  ZERO_BD, ZERO_BI, HALF_BD, ONE_BI,
  toUSDC, toTokens, outcomeIndexToName,
  getOrCreateProtocol, getOrCreateUser, getOrCreatePosition,
  updateAvgCost, computeProbabilityFromReserves
} from './helpers'
import { updateSnapshots } from './snapshots'

export function handleMarketCreated(event: MarketCreated): void {
  let conditionId = event.params.conditionId.toHexString()

  let market = Market.load(conditionId)
  if (market == null) {
    market = new Market(conditionId)
    market.category          = 'other'
    market.dataIpfsHash      = ''
    market.yesReserve        = ZERO_BD
    market.noReserve         = ZERO_BD
    market.liquidity         = ZERO_BD
    market.bestBid           = ZERO_BD
    market.bestAsk           = ZERO_BD
    market.probability       = HALF_BD
    market.lastTradePrice    = HALF_BD
    market.totalVolume       = ZERO_BD
    market.fpmmVolume        = ZERO_BD
    market.clobVolume        = ZERO_BD
    market.tradeCount        = ZERO_BI
    market.orderCount        = ZERO_BI
    market.uniqueTraderCount = ZERO_BI
    market.payouts           = []
  }

  market.question       = event.params.question
  market.description    = ''
  market.ipfsHash       = event.params.ipfsHash
  market.creator        = event.params.creator
  market.createdAt      = event.block.timestamp
  market.createdAtBlock = event.block.number
  market.resolutionTime = event.params.resolutionTime
  market.status         = 'Active'

  market.save()

  let user = getOrCreateUser(event.params.creator, event.block.timestamp)
  user.lastActiveAt = event.block.timestamp
  user.save()
}

export function handleLiquidityAdded(event: LiquidityAdded): void {
  let conditionId = event.params.conditionId.toHexString()
  let market = Market.load(conditionId)
  if (market == null) return

  let usdcAmount = toUSDC(event.params.amount)
  let lpShares   = toTokens(event.params.lpShares)

  market.liquidity = market.liquidity.plus(usdcAmount)
  market.save()

  let eventId = event.transaction.hash.toHexString() + '-' + event.logIndex.toString()
  let liqEvent = new LiquidityEvent(eventId)
  liqEvent.market      = market.id
  liqEvent.provider    = event.params.provider
  liqEvent.type        = 'ADD'
  liqEvent.usdcAmount  = usdcAmount
  liqEvent.lpShares    = lpShares
  liqEvent.timestamp   = event.block.timestamp
  liqEvent.blockNumber = event.block.number
  liqEvent.txHash      = event.transaction.hash
  liqEvent.save()

  let protocol = getOrCreateProtocol()
  protocol.totalLiquidity = protocol.totalLiquidity.plus(usdcAmount)
  protocol.updatedAt = event.block.timestamp
  protocol.save()

  let user = getOrCreateUser(event.params.provider, event.block.timestamp)
  user.lastActiveAt = event.block.timestamp
  user.save()
}

export function handleLiquidityRemoved(event: LiquidityRemoved): void {
  let conditionId = event.params.conditionId.toHexString()
  let market = Market.load(conditionId)
  if (market == null) return

  let lpShares = toTokens(event.params.lpShares)

  // Sum amounts array for total USDC removed
  let totalUsdc = ZERO_BD
  for (let i = 0; i < event.params.amounts.length; i++) {
    totalUsdc = totalUsdc.plus(toUSDC(event.params.amounts[i]))
  }

  market.liquidity = market.liquidity.gt(totalUsdc)
    ? market.liquidity.minus(totalUsdc)
    : ZERO_BD
  market.save()

  let eventId = event.transaction.hash.toHexString() + '-' + event.logIndex.toString()
  let liqEvent = new LiquidityEvent(eventId)
  liqEvent.market      = market.id
  liqEvent.provider    = event.params.provider
  liqEvent.type        = 'REMOVE'
  liqEvent.usdcAmount  = totalUsdc
  liqEvent.lpShares    = lpShares
  liqEvent.timestamp   = event.block.timestamp
  liqEvent.blockNumber = event.block.number
  liqEvent.txHash      = event.transaction.hash
  liqEvent.save()

  let protocol = getOrCreateProtocol()
  protocol.totalLiquidity = protocol.totalLiquidity.gt(totalUsdc)
    ? protocol.totalLiquidity.minus(totalUsdc)
    : ZERO_BD
  protocol.updatedAt = event.block.timestamp
  protocol.save()
}

export function handleOutcomeBought(event: OutcomeBought): void {
  let conditionId = event.params.conditionId.toHexString()
  let market = Market.load(conditionId)
  if (market == null) return

  let usdcAmount   = toUSDC(event.params.usdcAmount)
  let tokensBought = toTokens(event.params.tokensBought)
  let outcomeIndex = event.params.outcomeIndex
  let outcomeName  = outcomeIndexToName(outcomeIndex)

  // Price = usdcAmount / tokensBought (normalized to 0-1)
  let price = tokensBought.gt(ZERO_BD)
    ? usdcAmount.div(tokensBought)
    : HALF_BD

  // Record trade
  let tradeId = event.transaction.hash.toHexString() + '-' + event.logIndex.toString()
  let trade = new Trade(tradeId)
  trade.market       = market.id
  trade.conditionId  = event.params.conditionId
  trade.source       = 'FPMM'
  trade.buyer        = event.params.buyer
  trade.seller       = Address.zero()
  trade.outcomeIndex = outcomeIndex
  trade.outcomeName  = outcomeName
  trade.price        = price
  trade.size         = tokensBought
  trade.usdcVolume   = usdcAmount
  trade.timestamp    = event.block.timestamp
  trade.blockNumber  = event.block.number
  trade.txHash       = event.transaction.hash
  trade.save()

  // Update market
  market.lastTradePrice = price
  market.probability = outcomeIndex.isZero()
    ? price
    : (ONE_BI.toBigDecimal().minus(price))
  market.totalVolume = market.totalVolume.plus(usdcAmount)
  market.fpmmVolume  = market.fpmmVolume.plus(usdcAmount)
  market.tradeCount  = market.tradeCount.plus(ONE_BI)
  market.save()

  // Update position
  let position = getOrCreatePosition(
    event.params.conditionId, event.params.buyer, market as Market, event.block.timestamp
  )
  let wasNewTrader = position.totalInvested.equals(ZERO_BD)
  if (outcomeName == 'YES') {
    position.avgCostYes = updateAvgCost(position.yesShares, position.avgCostYes, tokensBought, price)
    position.yesShares  = position.yesShares.plus(tokensBought)
  } else {
    position.avgCostNo = updateAvgCost(position.noShares, position.avgCostNo, tokensBought, price)
    position.noShares  = position.noShares.plus(tokensBought)
  }
  position.totalInvested = position.totalInvested.plus(usdcAmount)
  position.updatedAt     = event.block.timestamp
  position.save()

  // Update user
  let user = getOrCreateUser(event.params.buyer, event.block.timestamp)
  if (wasNewTrader) {
    user.marketsTraded = user.marketsTraded.plus(ONE_BI)
    market.uniqueTraderCount = market.uniqueTraderCount.plus(ONE_BI)
    market.save()
  }
  user.totalVolume  = user.totalVolume.plus(usdcAmount)
  user.fpmmVolume   = user.fpmmVolume.plus(usdcAmount)
  user.tradeCount   = user.tradeCount.plus(ONE_BI)
  user.lastActiveAt = event.block.timestamp
  user.save()

  // Update protocol
  let protocol = getOrCreateProtocol()
  protocol.totalVolume = protocol.totalVolume.plus(usdcAmount)
  protocol.totalTrades = protocol.totalTrades.plus(ONE_BI)
  protocol.updatedAt   = event.block.timestamp
  protocol.save()

  updateSnapshots(market as Market, price, usdcAmount, event.block.timestamp)
}

export function handleOutcomeSold(event: OutcomeSold): void {
  let conditionId = event.params.conditionId.toHexString()
  let market = Market.load(conditionId)
  if (market == null) return

  let returnAmount = toUSDC(event.params.returnAmount)
  let tokensSold   = toTokens(event.params.tokensSold)
  let outcomeIndex = event.params.outcomeIndex
  let outcomeName  = outcomeIndexToName(outcomeIndex)

  let price = tokensSold.gt(ZERO_BD)
    ? returnAmount.div(tokensSold)
    : HALF_BD

  let tradeId = event.transaction.hash.toHexString() + '-' + event.logIndex.toString()
  let trade = new Trade(tradeId)
  trade.market       = market.id
  trade.conditionId  = event.params.conditionId
  trade.source       = 'FPMM'
  trade.buyer        = Address.zero()
  trade.seller       = event.params.seller
  trade.outcomeIndex = outcomeIndex
  trade.outcomeName  = outcomeName
  trade.price        = price
  trade.size         = tokensSold
  trade.usdcVolume   = returnAmount
  trade.timestamp    = event.block.timestamp
  trade.blockNumber  = event.block.number
  trade.txHash       = event.transaction.hash
  trade.save()

  market.lastTradePrice = price
  market.probability    = outcomeIndex.isZero() ? price : (ONE_BI.toBigDecimal().minus(price))
  market.totalVolume    = market.totalVolume.plus(returnAmount)
  market.fpmmVolume     = market.fpmmVolume.plus(returnAmount)
  market.tradeCount     = market.tradeCount.plus(ONE_BI)
  market.save()

  // Update position — reduce shares
  let position = getOrCreatePosition(
    event.params.conditionId, event.params.seller, market as Market, event.block.timestamp
  )
  // Realized PnL = return - (avg cost * tokens sold)
  let costBasis = outcomeName == 'YES'
    ? position.avgCostYes.times(tokensSold)
    : position.avgCostNo.times(tokensSold)

  if (outcomeName == 'YES') {
    position.yesShares = position.yesShares.gt(tokensSold)
      ? position.yesShares.minus(tokensSold)
      : ZERO_BD
  } else {
    position.noShares = position.noShares.gt(tokensSold)
      ? position.noShares.minus(tokensSold)
      : ZERO_BD
  }
  position.realizedPnl = position.realizedPnl.plus(returnAmount.minus(costBasis))
  position.updatedAt   = event.block.timestamp
  position.save()

  let user = getOrCreateUser(event.params.seller, event.block.timestamp)
  user.totalVolume  = user.totalVolume.plus(returnAmount)
  user.fpmmVolume   = user.fpmmVolume.plus(returnAmount)
  user.tradeCount   = user.tradeCount.plus(ONE_BI)
  user.realizedPnl  = user.realizedPnl.plus(returnAmount.minus(costBasis))
  user.lastActiveAt = event.block.timestamp
  user.save()

  let protocol = getOrCreateProtocol()
  protocol.totalVolume = protocol.totalVolume.plus(returnAmount)
  protocol.totalTrades = protocol.totalTrades.plus(ONE_BI)
  protocol.updatedAt   = event.block.timestamp
  protocol.save()

  updateSnapshots(market as Market, price, returnAmount, event.block.timestamp)
}

export function handleMarketResolved(event: MarketResolved): void {
  let conditionId = event.params.conditionId.toHexString()
  let market = Market.load(conditionId)
  if (market == null) return

  let payouts = event.params.payouts
  let outcome = 'INVALID'
  if (payouts.length >= 2) {
    if (payouts[0].gt(ZERO_BI) && payouts[1].equals(ZERO_BI)) outcome = 'YES'
    else if (payouts[1].gt(ZERO_BI) && payouts[0].equals(ZERO_BI)) outcome = 'NO'
  }

  market.status  = 'Resolved'
  market.outcome = outcome
  market.payouts = payouts
  market.probability = outcome == 'YES'
    ? ONE_BI.toBigDecimal()
    : (outcome == 'NO' ? ZERO_BD : HALF_BD)
  market.save()

  let protocol = getOrCreateProtocol()
  protocol.activeMarkets = protocol.activeMarkets.gt(ZERO_BI)
    ? protocol.activeMarkets.minus(ONE_BI)
    : ZERO_BI
  protocol.resolvedMarkets = protocol.resolvedMarkets.plus(ONE_BI)
  protocol.updatedAt       = event.block.timestamp
  protocol.save()
}

export function handleMarketCancelled(event: MarketCancelled): void {
  let conditionId = event.params.conditionId.toHexString()
  let market = Market.load(conditionId)
  if (market == null) return

  market.status = 'Cancelled'
  market.save()

  let protocol = getOrCreateProtocol()
  protocol.activeMarkets = protocol.activeMarkets.gt(ZERO_BI)
    ? protocol.activeMarkets.minus(ONE_BI)
    : ZERO_BI
  protocol.updatedAt = event.block.timestamp
  protocol.save()
}

export function handlePositionsRedeemed(event: PositionsRedeemed): void {
  let conditionId = event.params.conditionId.toHexString()
  let market = Market.load(conditionId)
  if (market == null) return

  let payout = toUSDC(event.params.payout)

  let position = getOrCreatePosition(
    event.params.conditionId, event.params.redeemer, market as Market, event.block.timestamp
  )

  let costBasis = position.avgCostYes.times(position.yesShares)
    .plus(position.avgCostNo.times(position.noShares))
  let pnl = payout.minus(costBasis)

  position.realizedPnl = position.realizedPnl.plus(pnl)
  position.yesShares   = ZERO_BD
  position.noShares    = ZERO_BD
  position.updatedAt   = event.block.timestamp
  position.save()

  let user = getOrCreateUser(event.params.redeemer, event.block.timestamp)
  user.realizedPnl  = user.realizedPnl.plus(pnl)
  user.lastActiveAt = event.block.timestamp
  user.save()
}
