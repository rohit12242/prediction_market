import { BigDecimal, BigInt } from '@graphprotocol/graph-ts'
import { MarketHourSnapshot, MarketDaySnapshot, Market } from '../generated/schema'
import { ZERO_BD, ZERO_BI, ONE_BI } from './helpers'

// 3600 seconds per hour
const HOUR = BigInt.fromI32(3600)
// 86400 seconds per day
const DAY = BigInt.fromI32(86400)

export function updateSnapshots(
  market: Market,
  price: BigDecimal,
  volume: BigDecimal,
  timestamp: BigInt
): void {
  updateHourSnapshot(market, price, volume, timestamp)
  updateDaySnapshot(market, price, volume, timestamp)
}

function updateHourSnapshot(
  market: Market,
  price: BigDecimal,
  volume: BigDecimal,
  timestamp: BigInt
): void {
  let hourIndex = timestamp.div(HOUR)
  let hourStart = hourIndex.times(HOUR)
  let id = market.id + '-h-' + hourIndex.toString()

  let snap = MarketHourSnapshot.load(id)
  if (snap == null) {
    snap = new MarketHourSnapshot(id)
    snap.market = market.id
    snap.timestamp = hourStart
    snap.hour = hourIndex.toI32()
    snap.open = price
    snap.high = price
    snap.low = price
    snap.close = price
    snap.volume = ZERO_BD
    snap.tradeCount = ZERO_BI
    snap.liquidity = market.liquidity
  } else {
    if (price.gt(snap.high)) snap.high = price
    if (price.lt(snap.low))  snap.low  = price
    snap.close = price
  }

  snap.volume = snap.volume.plus(volume)
  snap.tradeCount = snap.tradeCount.plus(ONE_BI)
  snap.liquidity = market.liquidity
  snap.save()
}

function updateDaySnapshot(
  market: Market,
  price: BigDecimal,
  volume: BigDecimal,
  timestamp: BigInt
): void {
  let dayIndex = timestamp.div(DAY)
  let dayStart = dayIndex.times(DAY)
  let id = market.id + '-d-' + dayIndex.toString()

  let snap = MarketDaySnapshot.load(id)
  if (snap == null) {
    snap = new MarketDaySnapshot(id)
    snap.market = market.id
    snap.timestamp = dayStart
    snap.date = dayIndex.toI32()
    snap.open = price
    snap.high = price
    snap.low = price
    snap.close = price
    snap.volume = ZERO_BD
    snap.tradeCount = ZERO_BI
    snap.liquidity = market.liquidity
  } else {
    if (price.gt(snap.high)) snap.high = price
    if (price.lt(snap.low))  snap.low  = price
    snap.close = price
  }

  snap.volume = snap.volume.plus(volume)
  snap.tradeCount = snap.tradeCount.plus(ONE_BI)
  snap.liquidity = market.liquidity
  snap.save()
}
