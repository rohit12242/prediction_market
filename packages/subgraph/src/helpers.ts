import { BigDecimal, BigInt, Bytes, Address } from '@graphprotocol/graph-ts'
import { Protocol, Market, User, Position } from '../generated/schema'

export const ZERO_BI = BigInt.fromI32(0)
export const ONE_BI = BigInt.fromI32(1)
export const ZERO_BD = BigDecimal.fromString('0')
export const ONE_BD = BigDecimal.fromString('1')
export const HALF_BD = BigDecimal.fromString('0.5')

// Denominators for normalization
export const USDC_DECIMALS = BigDecimal.fromString('1000000')             // 1e6
export const TOKEN_DECIMALS = BigDecimal.fromString('1000000000000000000') // 1e18
export const PRICE_DENOMINATOR = BigDecimal.fromString('1000000')         // CLOB price scaling

export const PROTOCOL_ID = 'fluxmarkets'

export function toUSDC(raw: BigInt): BigDecimal {
  return raw.toBigDecimal().div(USDC_DECIMALS)
}

export function toTokens(raw: BigInt): BigDecimal {
  return raw.toBigDecimal().div(TOKEN_DECIMALS)
}

export function toPrice(rawPrice: BigInt): BigDecimal {
  // CLOB price: 500000 → 0.5
  return rawPrice.toBigDecimal().div(PRICE_DENOMINATOR)
}

export function outcomeIndexToName(index: BigInt): string {
  return index.equals(ZERO_BI) ? 'YES' : 'NO'
}

export function sideToString(side: i32): string {
  return side == 0 ? 'BUY' : 'SELL'
}

export function getOrCreateProtocol(): Protocol {
  let protocol = Protocol.load(PROTOCOL_ID)
  if (protocol == null) {
    protocol = new Protocol(PROTOCOL_ID)
    protocol.totalMarkets = ZERO_BI
    protocol.activeMarkets = ZERO_BI
    protocol.resolvedMarkets = ZERO_BI
    protocol.totalVolume = ZERO_BD
    protocol.totalLiquidity = ZERO_BD
    protocol.totalUsers = ZERO_BI
    protocol.totalTrades = ZERO_BI
    protocol.totalOrders = ZERO_BI
    protocol.updatedAt = ZERO_BI
    protocol.save()
  }
  return protocol as Protocol
}

export function getOrCreateUser(address: Address, timestamp: BigInt): User {
  let id = address.toHexString()
  let user = User.load(id)
  if (user == null) {
    user = new User(id)
    user.totalVolume = ZERO_BD
    user.fpmmVolume = ZERO_BD
    user.clobVolume = ZERO_BD
    user.marketsTraded = ZERO_BI
    user.marketsCreated = ZERO_BI
    user.tradeCount = ZERO_BI
    user.orderCount = ZERO_BI
    user.realizedPnl = ZERO_BD
    user.createdAt = timestamp
    user.lastActiveAt = timestamp
    user.save()

    let protocol = getOrCreateProtocol()
    protocol.totalUsers = protocol.totalUsers.plus(ONE_BI)
    protocol.save()
  }
  return user as User
}

export function getOrCreatePosition(
  conditionId: Bytes,
  userAddress: Address,
  market: Market,
  timestamp: BigInt
): Position {
  let id = conditionId.toHexString() + '-' + userAddress.toHexString()
  let position = Position.load(id)
  if (position == null) {
    position = new Position(id)
    position.market = market.id
    position.user = userAddress.toHexString()
    position.yesShares = ZERO_BD
    position.noShares = ZERO_BD
    position.avgCostYes = ZERO_BD
    position.avgCostNo = ZERO_BD
    position.totalInvested = ZERO_BD
    position.realizedPnl = ZERO_BD
    position.updatedAt = timestamp
    position.save()
  }
  return position as Position
}

// Weighted average cost calculation (for position tracking)
export function updateAvgCost(
  currentShares: BigDecimal,
  currentAvgCost: BigDecimal,
  newShares: BigDecimal,
  newPrice: BigDecimal
): BigDecimal {
  let totalShares = currentShares.plus(newShares)
  if (totalShares.equals(ZERO_BD)) return ZERO_BD
  let totalCost = currentShares.times(currentAvgCost).plus(newShares.times(newPrice))
  return totalCost.div(totalShares)
}

// Compute YES probability from FPMM reserves
// In CPMM: P(YES) = noReserve / (yesReserve + noReserve)
export function computeProbabilityFromReserves(
  yesReserve: BigDecimal,
  noReserve: BigDecimal
): BigDecimal {
  let total = yesReserve.plus(noReserve)
  if (total.equals(ZERO_BD)) return HALF_BD
  return noReserve.div(total)
}
