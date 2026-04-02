import { Address, Bytes } from '@graphprotocol/graph-ts'
import {
  FPMMFundingAdded, FPMMFundingRemoved, FPMMBuy, FPMMSell
} from '../generated/templates/FixedProductMarketMaker/FixedProductMarketMaker'
import { Market, LiquidityEvent, Trade, FPMMMarketLink } from '../generated/schema'
import {
  ZERO_BD, ZERO_BI, HALF_BD, ONE_BI,
  toUSDC, toTokens, outcomeIndexToName,
  getOrCreateProtocol, getOrCreateUser,
  computeProbabilityFromReserves
} from './helpers'
import { updateSnapshots } from './snapshots'

function getMarket(fpmmAddress: Address): Market | null {
  let link = FPMMMarketLink.load(fpmmAddress.toHexString())
  if (link == null) return null
  return Market.load(link.market)
}

export function handleFPMMFundingAdded(event: FPMMFundingAdded): void {
  let market = getMarket(event.address)
  if (market == null) return

  // amountsAdded[0] = YES tokens added, amountsAdded[1] = NO tokens added
  let amounts = event.params.amountsAdded
  if (amounts.length >= 2) {
    market.yesReserve = market.yesReserve.plus(toTokens(amounts[0]))
    market.noReserve  = market.noReserve.plus(toTokens(amounts[1]))
    market.probability = computeProbabilityFromReserves(market.yesReserve, market.noReserve)
  }

  // Liquidity approximation: USDC equivalent of shares minted
  let shares = toTokens(event.params.sharesMinted)
  market.liquidity = market.liquidity.plus(shares)
  market.save()

  let eventId = event.transaction.hash.toHexString() + '-' + event.logIndex.toString()
  let liqEvent = new LiquidityEvent(eventId)
  liqEvent.market      = market.id
  liqEvent.provider    = event.params.funder
  liqEvent.type        = 'ADD'
  liqEvent.usdcAmount  = shares
  liqEvent.lpShares    = shares
  liqEvent.timestamp   = event.block.timestamp
  liqEvent.blockNumber = event.block.number
  liqEvent.txHash      = event.transaction.hash
  liqEvent.save()

  let protocol = getOrCreateProtocol()
  protocol.totalLiquidity = protocol.totalLiquidity.plus(shares)
  protocol.updatedAt      = event.block.timestamp
  protocol.save()
}

export function handleFPMMFundingRemoved(event: FPMMFundingRemoved): void {
  let market = getMarket(event.address)
  if (market == null) return

  let amounts = event.params.amountsRemoved
  if (amounts.length >= 2) {
    let yesRemoved = toTokens(amounts[0])
    let noRemoved  = toTokens(amounts[1])
    market.yesReserve = market.yesReserve.gt(yesRemoved) ? market.yesReserve.minus(yesRemoved) : ZERO_BD
    market.noReserve  = market.noReserve.gt(noRemoved)   ? market.noReserve.minus(noRemoved)   : ZERO_BD
    market.probability = computeProbabilityFromReserves(market.yesReserve, market.noReserve)
  }

  let shares = toTokens(event.params.sharesBurnt)
  market.liquidity = market.liquidity.gt(shares) ? market.liquidity.minus(shares) : ZERO_BD
  market.save()

  let eventId = event.transaction.hash.toHexString() + '-' + event.logIndex.toString()
  let liqEvent = new LiquidityEvent(eventId)
  liqEvent.market      = market.id
  liqEvent.provider    = event.params.funder
  liqEvent.type        = 'REMOVE'
  liqEvent.usdcAmount  = shares
  liqEvent.lpShares    = shares
  liqEvent.timestamp   = event.block.timestamp
  liqEvent.blockNumber = event.block.number
  liqEvent.txHash      = event.transaction.hash
  liqEvent.save()

  let protocol = getOrCreateProtocol()
  protocol.totalLiquidity = protocol.totalLiquidity.gt(shares)
    ? protocol.totalLiquidity.minus(shares)
    : ZERO_BD
  protocol.updatedAt = event.block.timestamp
  protocol.save()
}

export function handleFPMMBuy(event: FPMMBuy): void {
  let market = getMarket(event.address)
  if (market == null) return

  let usdcAmount   = toUSDC(event.params.investmentAmount)
  let feeAmount    = toUSDC(event.params.feeAmount)
  let netAmount    = usdcAmount.minus(feeAmount)
  let tokensBought = toTokens(event.params.outcomeTokensBought)
  let outcomeIndex = event.params.outcomeIndex
  let outcomeName  = outcomeIndexToName(outcomeIndex)

  // Update reserves — buying YES removes YES tokens from reserve, adds net investment
  // split equally; then remove exactly the bought tokens from the target reserve.
  if (outcomeName == 'YES') {
    market.yesReserve = market.yesReserve.plus(netAmount).minus(tokensBought)
    market.noReserve  = market.noReserve.plus(netAmount)
  } else {
    market.yesReserve = market.yesReserve.plus(netAmount)
    market.noReserve  = market.noReserve.plus(netAmount).minus(tokensBought)
  }
  if (market.yesReserve.lt(ZERO_BD)) market.yesReserve = ZERO_BD
  if (market.noReserve.lt(ZERO_BD))  market.noReserve  = ZERO_BD

  let price = tokensBought.gt(ZERO_BD) ? usdcAmount.div(tokensBought) : HALF_BD
  market.probability    = computeProbabilityFromReserves(market.yesReserve, market.noReserve)
  market.lastTradePrice = price
  market.totalVolume    = market.totalVolume.plus(usdcAmount)
  market.fpmmVolume     = market.fpmmVolume.plus(usdcAmount)
  market.tradeCount     = market.tradeCount.plus(ONE_BI)
  market.save()

  // Record trade
  let tradeId = event.transaction.hash.toHexString() + '-' + event.logIndex.toString()
  let trade = new Trade(tradeId)
  trade.market       = market.id
  trade.conditionId  = Bytes.fromHexString(market.id) as Bytes
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

  let user = getOrCreateUser(event.params.buyer, event.block.timestamp)
  user.totalVolume  = user.totalVolume.plus(usdcAmount)
  user.fpmmVolume   = user.fpmmVolume.plus(usdcAmount)
  user.tradeCount   = user.tradeCount.plus(ONE_BI)
  user.lastActiveAt = event.block.timestamp
  user.save()

  let protocol = getOrCreateProtocol()
  protocol.totalVolume = protocol.totalVolume.plus(usdcAmount)
  protocol.totalTrades = protocol.totalTrades.plus(ONE_BI)
  protocol.updatedAt   = event.block.timestamp
  protocol.save()

  updateSnapshots(market as Market, price, usdcAmount, event.block.timestamp)
}

export function handleFPMMSell(event: FPMMSell): void {
  let market = getMarket(event.address)
  if (market == null) return

  let returnAmount = toUSDC(event.params.returnAmount)
  let tokensSold   = toTokens(event.params.outcomeTokensSold)
  let outcomeIndex = event.params.outcomeIndex
  let outcomeName  = outcomeIndexToName(outcomeIndex)
  let price        = tokensSold.gt(ZERO_BD) ? returnAmount.div(tokensSold) : HALF_BD

  market.probability    = computeProbabilityFromReserves(market.yesReserve, market.noReserve)
  market.lastTradePrice = price
  market.totalVolume    = market.totalVolume.plus(returnAmount)
  market.fpmmVolume     = market.fpmmVolume.plus(returnAmount)
  market.tradeCount     = market.tradeCount.plus(ONE_BI)
  market.save()

  let tradeId = event.transaction.hash.toHexString() + '-' + event.logIndex.toString()
  let trade = new Trade(tradeId)
  trade.market       = market.id
  trade.conditionId  = Bytes.fromHexString(market.id) as Bytes
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

  let user = getOrCreateUser(event.params.seller, event.block.timestamp)
  user.totalVolume  = user.totalVolume.plus(returnAmount)
  user.fpmmVolume   = user.fpmmVolume.plus(returnAmount)
  user.tradeCount   = user.tradeCount.plus(ONE_BI)
  user.lastActiveAt = event.block.timestamp
  user.save()

  let protocol = getOrCreateProtocol()
  protocol.totalVolume = protocol.totalVolume.plus(returnAmount)
  protocol.totalTrades = protocol.totalTrades.plus(ONE_BI)
  protocol.updatedAt   = event.block.timestamp
  protocol.save()

  updateSnapshots(market as Market, price, returnAmount, event.block.timestamp)
}
