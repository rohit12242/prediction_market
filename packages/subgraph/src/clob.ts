import { Address, BigInt, Bytes } from '@graphprotocol/graph-ts'
import {
  OrderPlaced, OrderFilled, OrderPartiallyFilled,
  OrderCancelled, TradeExecuted
} from '../generated/templates/CLOBOrderBook/CLOBOrderBook'
import { Market, Order, Trade, CLOBMarketLink } from '../generated/schema'
import {
  ZERO_BD, ZERO_BI, HALF_BD, ONE_BI,
  toUSDC, toTokens, toPrice, outcomeIndexToName, sideToString,
  getOrCreateProtocol, getOrCreateUser, getOrCreatePosition,
  updateAvgCost
} from './helpers'
import { updateSnapshots } from './snapshots'

function getMarketFromCLOB(clobAddress: Address): Market | null {
  let link = CLOBMarketLink.load(clobAddress.toHexString())
  if (link == null) return null
  return Market.load(link.market)
}

export function handleOrderPlaced(event: OrderPlaced): void {
  let market = getMarketFromCLOB(event.address)
  if (market == null) return

  let side         = sideToString(event.params.side)
  let outcomeIndex = event.params.outcomeIndex
  let outcomeName  = outcomeIndexToName(outcomeIndex)
  let price        = toPrice(event.params.price)
  let size         = toTokens(event.params.amount)
  // BUY orders lock USDC; SELL orders lock outcome tokens
  let usdcCommitted = side == 'BUY'
    ? price.times(size)
    : ZERO_BD

  let orderId = event.params.orderId.toHexString()
  let order   = new Order(orderId)
  order.market         = market.id
  order.conditionId    = Bytes.fromHexString(market.id) as Bytes
  order.trader         = event.params.trader.toHexString()
  order.side           = side
  order.outcomeIndex   = outcomeIndex
  order.outcomeName    = outcomeName
  order.price          = price
  order.originalSize   = size
  order.filledSize     = ZERO_BD
  order.remainingSize  = size
  order.usdcCommitted  = usdcCommitted
  order.status         = 'Open'
  order.createdAt      = event.block.timestamp
  order.updatedAt      = event.block.timestamp
  order.blockNumber    = event.block.number
  order.txHash         = event.transaction.hash
  order.save()

  market.orderCount = market.orderCount.plus(ONE_BI)
  // Update CLOB best bid/ask
  if (side == 'BUY') {
    if (market.bestBid.equals(ZERO_BD) || price.gt(market.bestBid)) {
      market.bestBid = price
    }
  } else {
    if (market.bestAsk.equals(ZERO_BD) || price.lt(market.bestAsk)) {
      market.bestAsk = price
    }
  }
  market.save()

  let user = getOrCreateUser(event.params.trader, event.block.timestamp)
  user.orderCount   = user.orderCount.plus(ONE_BI)
  user.lastActiveAt = event.block.timestamp
  user.save()

  let protocol = getOrCreateProtocol()
  protocol.totalOrders = protocol.totalOrders.plus(ONE_BI)
  protocol.updatedAt   = event.block.timestamp
  protocol.save()
}

export function handleOrderFilled(event: OrderFilled): void {
  let orderId = event.params.orderId.toHexString()
  let order   = Order.load(orderId)
  if (order == null) return

  let filled = toTokens(event.params.filledAmount)
  order.filledSize    = order.filledSize.plus(filled)
  order.remainingSize = order.remainingSize.gt(filled)
    ? order.remainingSize.minus(filled)
    : ZERO_BD
  order.status    = 'Filled'
  order.updatedAt = event.block.timestamp
  order.save()
}

export function handleOrderPartiallyFilled(event: OrderPartiallyFilled): void {
  let orderId = event.params.orderId.toHexString()
  let order   = Order.load(orderId)
  if (order == null) return

  let filled    = toTokens(event.params.filledAmount)
  let remaining = toTokens(event.params.remainingAmount)
  order.filledSize    = order.filledSize.plus(filled)
  order.remainingSize = remaining
  order.status        = 'PartiallyFilled'
  order.updatedAt     = event.block.timestamp
  order.save()
}

export function handleOrderCancelled(event: OrderCancelled): void {
  let orderId = event.params.orderId.toHexString()
  let order   = Order.load(orderId)
  if (order == null) return

  order.status    = 'Cancelled'
  order.updatedAt = event.block.timestamp
  order.save()

  let user = getOrCreateUser(event.params.trader, event.block.timestamp)
  user.lastActiveAt = event.block.timestamp
  user.save()
}

export function handleTradeExecuted(event: TradeExecuted): void {
  let market = getMarketFromCLOB(event.address)
  if (market == null) return

  let price        = toPrice(event.params.price)
  let size         = toTokens(event.params.amount)
  let usdcVolume   = price.times(size)
  let outcomeIndex = event.params.outcomeIndex
  let outcomeName  = outcomeIndexToName(outcomeIndex)

  // Derive buyer/seller from the order entities
  let buyOrderId  = event.params.buyOrderId.toHexString()
  let sellOrderId = event.params.sellOrderId.toHexString()
  let buyOrder    = Order.load(buyOrderId)
  let sellOrder   = Order.load(sellOrderId)
  let buyerAddr   = buyOrder  != null ? Address.fromString(buyOrder.trader)  : Address.zero()
  let sellerAddr  = sellOrder != null ? Address.fromString(sellOrder.trader) : Address.zero()

  // Record the trade
  let tradeId = event.transaction.hash.toHexString() + '-' + event.logIndex.toString()
  let trade   = new Trade(tradeId)
  trade.market       = market.id
  trade.conditionId  = Bytes.fromHexString(market.id) as Bytes
  trade.source       = 'CLOB'
  trade.buyer        = buyerAddr
  trade.seller       = sellerAddr
  trade.outcomeIndex = outcomeIndex
  trade.outcomeName  = outcomeName
  trade.price        = price
  trade.size         = size
  trade.usdcVolume   = usdcVolume
  trade.timestamp    = event.block.timestamp
  trade.blockNumber  = event.block.number
  trade.txHash       = event.transaction.hash
  trade.save()

  // Update market
  market.lastTradePrice = price
  market.probability    = outcomeIndex.isZero()
    ? price
    : (ONE_BI.toBigDecimal().minus(price))
  market.totalVolume = market.totalVolume.plus(usdcVolume)
  market.clobVolume  = market.clobVolume.plus(usdcVolume)
  market.tradeCount  = market.tradeCount.plus(ONE_BI)
  market.save()

  // Update buyer position
  if (!buyerAddr.equals(Address.zero())) {
    let condIdBytes = Bytes.fromHexString(market.id) as Bytes
    let buyerPos = getOrCreatePosition(
      condIdBytes, buyerAddr, market as Market, event.block.timestamp
    )
    if (outcomeName == 'YES') {
      buyerPos.avgCostYes = updateAvgCost(buyerPos.yesShares, buyerPos.avgCostYes, size, price)
      buyerPos.yesShares  = buyerPos.yesShares.plus(size)
    } else {
      buyerPos.avgCostNo = updateAvgCost(buyerPos.noShares, buyerPos.avgCostNo, size, price)
      buyerPos.noShares  = buyerPos.noShares.plus(size)
    }
    buyerPos.totalInvested = buyerPos.totalInvested.plus(usdcVolume)
    buyerPos.updatedAt     = event.block.timestamp
    buyerPos.save()

    let buyer = getOrCreateUser(buyerAddr, event.block.timestamp)
    buyer.totalVolume  = buyer.totalVolume.plus(usdcVolume)
    buyer.clobVolume   = buyer.clobVolume.plus(usdcVolume)
    buyer.tradeCount   = buyer.tradeCount.plus(ONE_BI)
    buyer.lastActiveAt = event.block.timestamp
    buyer.save()
  }

  // Update seller position
  if (!sellerAddr.equals(Address.zero())) {
    let condIdBytes = Bytes.fromHexString(market.id) as Bytes
    let sellerPos = getOrCreatePosition(
      condIdBytes, sellerAddr, market as Market, event.block.timestamp
    )
    let costBasis = outcomeName == 'YES'
      ? sellerPos.avgCostYes.times(size)
      : sellerPos.avgCostNo.times(size)
    let pnl = usdcVolume.minus(costBasis)

    if (outcomeName == 'YES') {
      sellerPos.yesShares = sellerPos.yesShares.gt(size)
        ? sellerPos.yesShares.minus(size)
        : ZERO_BD
    } else {
      sellerPos.noShares = sellerPos.noShares.gt(size)
        ? sellerPos.noShares.minus(size)
        : ZERO_BD
    }
    sellerPos.realizedPnl = sellerPos.realizedPnl.plus(pnl)
    sellerPos.updatedAt   = event.block.timestamp
    sellerPos.save()

    let seller = getOrCreateUser(sellerAddr, event.block.timestamp)
    seller.totalVolume  = seller.totalVolume.plus(usdcVolume)
    seller.clobVolume   = seller.clobVolume.plus(usdcVolume)
    seller.tradeCount   = seller.tradeCount.plus(ONE_BI)
    seller.realizedPnl  = seller.realizedPnl.plus(pnl)
    seller.lastActiveAt = event.block.timestamp
    seller.save()
  }

  let protocol = getOrCreateProtocol()
  protocol.totalVolume = protocol.totalVolume.plus(usdcVolume)
  protocol.totalTrades = protocol.totalTrades.plus(ONE_BI)
  protocol.updatedAt   = event.block.timestamp
  protocol.save()

  updateSnapshots(market as Market, price, usdcVolume, event.block.timestamp)
}
