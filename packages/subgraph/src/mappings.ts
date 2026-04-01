import { BigDecimal, BigInt, Bytes } from "@graphprotocol/graph-ts"
import {
  MarketCreated,
  SharesBought,
  SharesSold,
  MarketResolved,
  Redeemed,
} from "../generated/PredictionMarket/PredictionMarket"
import { Market, Trade, Position, Resolution } from "../generated/schema"

const DECIMALS = BigDecimal.fromString("1000000000000000000") // 1e18

function toDecimal(value: BigInt): BigDecimal {
  return value.toBigDecimal().div(DECIMALS)
}

function outcomeToString(outcome: i32): string {
  if (outcome == 1) return "Yes"
  if (outcome == 2) return "No"
  if (outcome == 3) return "Invalid"
  return "Unresolved"
}

export function handleMarketCreated(event: MarketCreated): void {
  let market = new Market(event.params.marketId.toString())
  market.creator = event.params.creator
  market.question = event.params.question
  market.description = ""
  market.endTime = event.params.endTime
  market.resolutionTime = BigInt.fromI32(0)
  market.outcome = "Unresolved"
  market.yesShares = BigDecimal.fromString("0")
  market.noShares = BigDecimal.fromString("0")
  market.totalLiquidity = BigDecimal.fromString("0")
  market.resolved = false
  market.createdAt = event.block.timestamp
  market.createdAtBlock = event.block.number
  market.save()
}

export function handleSharesBought(event: SharesBought): void {
  let marketId = event.params.marketId.toString()
  let market = Market.load(marketId)
  if (!market) return

  let tradeId = event.transaction.hash.toHex() + "-" + event.logIndex.toString()
  let trade = new Trade(tradeId)
  trade.market = marketId
  trade.trader = event.params.buyer
  trade.isYes = event.params.isYes
  trade.amountIn = toDecimal(event.params.amount)
  trade.sharesOut = toDecimal(event.params.shares)
  trade.timestamp = event.block.timestamp
  trade.blockNumber = event.block.number
  trade.txHash = event.transaction.hash
  trade.save()

  // Update market shares
  if (event.params.isYes) {
    market.yesShares = market.yesShares.plus(toDecimal(event.params.shares))
  } else {
    market.noShares = market.noShares.plus(toDecimal(event.params.shares))
  }
  market.totalLiquidity = market.totalLiquidity.plus(toDecimal(event.params.amount))
  market.save()

  // Update position
  let positionId = marketId + "-" + event.params.buyer.toHex()
  let position = Position.load(positionId)
  if (!position) {
    position = new Position(positionId)
    position.market = marketId
    position.trader = event.params.buyer
    position.yesShares = BigDecimal.fromString("0")
    position.noShares = BigDecimal.fromString("0")
    position.totalInvested = BigDecimal.fromString("0")
    position.realizedPnl = BigDecimal.fromString("0")
  }
  if (event.params.isYes) {
    position.yesShares = position.yesShares.plus(toDecimal(event.params.shares))
  } else {
    position.noShares = position.noShares.plus(toDecimal(event.params.shares))
  }
  position.totalInvested = position.totalInvested.plus(toDecimal(event.params.amount))
  position.updatedAt = event.block.timestamp
  position.save()
}

export function handleSharesSold(event: SharesSold): void {
  let marketId = event.params.marketId.toString()
  let market = Market.load(marketId)
  if (!market) return

  if (event.params.isYes) {
    market.yesShares = market.yesShares.minus(toDecimal(event.params.shares))
  } else {
    market.noShares = market.noShares.minus(toDecimal(event.params.shares))
  }
  market.save()
}

export function handleMarketResolved(event: MarketResolved): void {
  let marketId = event.params.marketId.toString()
  let market = Market.load(marketId)
  if (!market) return

  market.outcome = outcomeToString(event.params.outcome)
  market.resolved = true
  market.save()

  let resolution = new Resolution(marketId)
  resolution.market = marketId
  resolution.outcome = outcomeToString(event.params.outcome)
  resolution.resolvedAt = event.block.timestamp
  resolution.resolvedAtBlock = event.block.number
  resolution.txHash = event.transaction.hash
  resolution.save()
}

export function handleRedeemed(event: Redeemed): void {
  let marketId = event.params.marketId.toString()
  let positionId = marketId + "-" + event.params.user.toHex()
  let position = Position.load(positionId)
  if (!position) return

  position.realizedPnl = toDecimal(event.params.payout).minus(position.totalInvested)
  position.yesShares = BigDecimal.fromString("0")
  position.noShares = BigDecimal.fromString("0")
  position.updatedAt = event.block.timestamp
  position.save()
}
