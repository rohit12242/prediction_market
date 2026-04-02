import {
  describe,
  test,
  beforeEach,
  afterEach,
  clearStore,
  assert
} from 'matchstick-as/assembly/index'
import { newMockEvent } from 'matchstick-as'
import { ethereum, Address, Bytes, BigInt } from '@graphprotocol/graph-ts'
import {
  MarketCreated,
  OutcomeBought,
  MarketResolved,
  PositionsRedeemed
} from '../generated/PredictionMarket/PredictionMarket'
import {
  handleMarketCreated,
  handleOutcomeBought,
  handleMarketResolved,
  handlePositionsRedeemed
} from '../src/predictionMarket'

// ── Event factory helpers ────────────────────────────────────────────────────

function createMarketCreatedEvent(
  conditionId: Bytes,
  creator: Address,
  question: string,
  ipfsHash: string,
  resolutionTime: BigInt
): MarketCreated {
  let mockEvent = changetype<MarketCreated>(newMockEvent())
  mockEvent.parameters = []
  mockEvent.parameters.push(new ethereum.EventParam('conditionId',    ethereum.Value.fromFixedBytes(conditionId)))
  mockEvent.parameters.push(new ethereum.EventParam('creator',        ethereum.Value.fromAddress(creator)))
  mockEvent.parameters.push(new ethereum.EventParam('question',       ethereum.Value.fromString(question)))
  mockEvent.parameters.push(new ethereum.EventParam('ipfsHash',       ethereum.Value.fromString(ipfsHash)))
  mockEvent.parameters.push(new ethereum.EventParam('resolutionTime', ethereum.Value.fromUnsignedBigInt(resolutionTime)))
  return mockEvent
}

function createOutcomeBoughtEvent(
  conditionId: Bytes,
  buyer: Address,
  outcomeIndex: BigInt,
  usdcAmount: BigInt,
  tokensBought: BigInt
): OutcomeBought {
  let mockEvent = changetype<OutcomeBought>(newMockEvent())
  mockEvent.parameters = []
  mockEvent.parameters.push(new ethereum.EventParam('conditionId',  ethereum.Value.fromFixedBytes(conditionId)))
  mockEvent.parameters.push(new ethereum.EventParam('buyer',        ethereum.Value.fromAddress(buyer)))
  mockEvent.parameters.push(new ethereum.EventParam('outcomeIndex', ethereum.Value.fromUnsignedBigInt(outcomeIndex)))
  mockEvent.parameters.push(new ethereum.EventParam('usdcAmount',   ethereum.Value.fromUnsignedBigInt(usdcAmount)))
  mockEvent.parameters.push(new ethereum.EventParam('tokensBought', ethereum.Value.fromUnsignedBigInt(tokensBought)))
  return mockEvent
}

function createMarketResolvedEvent(
  conditionId: Bytes,
  payouts: BigInt[]
): MarketResolved {
  let mockEvent = changetype<MarketResolved>(newMockEvent())
  mockEvent.parameters = []
  mockEvent.parameters.push(new ethereum.EventParam('conditionId', ethereum.Value.fromFixedBytes(conditionId)))
  mockEvent.parameters.push(new ethereum.EventParam('payouts',     ethereum.Value.fromUnsignedBigIntArray(payouts)))
  return mockEvent
}

function createPositionsRedeemedEvent(
  conditionId: Bytes,
  redeemer: Address,
  payout: BigInt
): PositionsRedeemed {
  let mockEvent = changetype<PositionsRedeemed>(newMockEvent())
  mockEvent.parameters = []
  mockEvent.parameters.push(new ethereum.EventParam('conditionId', ethereum.Value.fromFixedBytes(conditionId)))
  mockEvent.parameters.push(new ethereum.EventParam('redeemer',    ethereum.Value.fromAddress(redeemer)))
  mockEvent.parameters.push(new ethereum.EventParam('payout',      ethereum.Value.fromUnsignedBigInt(payout)))
  return mockEvent
}

// ── Test data constants ──────────────────────────────────────────────────────

const CONDITION_ID = Bytes.fromHexString(
  '0xaaaa000000000000000000000000000000000000000000000000000000000001'
)
const CREATOR   = Address.fromString('0x1000000000000000000000000000000000000001')
const BUYER     = Address.fromString('0x2000000000000000000000000000000000000002')
const QUESTION  = 'Will ETH reach $10k in 2026?'
const IPFS_HASH = 'QmTestIpfsHash'
const RES_TIME  = BigInt.fromI32(1893456000)

// ── Tests ────────────────────────────────────────────────────────────────────

describe('handleMarketCreated', () => {
  beforeEach(() => { clearStore() })
  afterEach(() => { clearStore() })

  test('creates Market entity with correct fields', () => {
    let event = createMarketCreatedEvent(CONDITION_ID, CREATOR, QUESTION, IPFS_HASH, RES_TIME)
    handleMarketCreated(event)

    let marketId = CONDITION_ID.toHexString()
    assert.entityCount('Market', 1)
    assert.fieldEquals('Market', marketId, 'question', QUESTION)
    assert.fieldEquals('Market', marketId, 'ipfsHash', IPFS_HASH)
    assert.fieldEquals('Market', marketId, 'status', 'Active')
    assert.fieldEquals('Market', marketId, 'creator', CREATOR.toHexString())
    assert.fieldEquals('Market', marketId, 'resolutionTime', RES_TIME.toString())
    assert.fieldEquals('Market', marketId, 'totalVolume', '0')
    assert.fieldEquals('Market', marketId, 'tradeCount', '0')
    assert.fieldEquals('Market', marketId, 'probability', '0.5')
  })

  test('does not duplicate Market on double call', () => {
    let event1 = createMarketCreatedEvent(CONDITION_ID, CREATOR, QUESTION, IPFS_HASH, RES_TIME)
    let event2 = createMarketCreatedEvent(CONDITION_ID, CREATOR, 'Updated?', IPFS_HASH, RES_TIME)
    handleMarketCreated(event1)
    handleMarketCreated(event2)

    assert.entityCount('Market', 1)
    // Second call updates question
    assert.fieldEquals('Market', CONDITION_ID.toHexString(), 'question', 'Updated?')
  })
})

describe('handleOutcomeBought', () => {
  beforeEach(() => {
    clearStore()
    // Pre-create the market
    let event = createMarketCreatedEvent(CONDITION_ID, CREATOR, QUESTION, IPFS_HASH, RES_TIME)
    handleMarketCreated(event)
  })
  afterEach(() => { clearStore() })

  test('creates Trade entity with source=FPMM', () => {
    // Buy 500 YES tokens for 250 USDC  (price = 0.5)
    // USDC 250_000_000 (6 dec) = $250; tokens = 500_000_000_000_000_000_000 (18 dec) = 500
    let usdcRaw    = BigInt.fromString('250000000')              // 250 USDC
    let tokensRaw  = BigInt.fromString('500000000000000000000')  // 500 tokens
    let event      = createOutcomeBoughtEvent(CONDITION_ID, BUYER, BigInt.fromI32(0), usdcRaw, tokensRaw)
    handleOutcomeBought(event)

    assert.entityCount('Trade', 1)
    let tradeId = event.transaction.hash.toHexString() + '-' + event.logIndex.toString()
    assert.fieldEquals('Trade', tradeId, 'source', 'FPMM')
    assert.fieldEquals('Trade', tradeId, 'outcomeName', 'YES')
    assert.fieldEquals('Trade', tradeId, 'buyer', BUYER.toHexString())
  })

  test('updates Market volume and tradeCount', () => {
    let usdcRaw   = BigInt.fromString('250000000')
    let tokensRaw = BigInt.fromString('500000000000000000000')
    let event     = createOutcomeBoughtEvent(CONDITION_ID, BUYER, BigInt.fromI32(0), usdcRaw, tokensRaw)
    handleOutcomeBought(event)

    let marketId = CONDITION_ID.toHexString()
    assert.fieldEquals('Market', marketId, 'tradeCount', '1')
    assert.fieldEquals('Market', marketId, 'totalVolume', '250')
    assert.fieldEquals('Market', marketId, 'fpmmVolume', '250')
  })

  test('creates Position entity for buyer', () => {
    let usdcRaw   = BigInt.fromString('250000000')
    let tokensRaw = BigInt.fromString('500000000000000000000')
    let event     = createOutcomeBoughtEvent(CONDITION_ID, BUYER, BigInt.fromI32(0), usdcRaw, tokensRaw)
    handleOutcomeBought(event)

    let posId = CONDITION_ID.toHexString() + '-' + BUYER.toHexString()
    assert.entityCount('Position', 1)
    assert.fieldEquals('Position', posId, 'yesShares', '500')
    assert.fieldEquals('Position', posId, 'noShares', '0')
    assert.fieldEquals('Position', posId, 'totalInvested', '250')
  })

  test('sets NO probability when outcomeIndex=0 (YES buy)', () => {
    let usdcRaw   = BigInt.fromString('500000000')              // $500
    let tokensRaw = BigInt.fromString('1000000000000000000000') // 1000 tokens → price = 0.5
    let event     = createOutcomeBoughtEvent(CONDITION_ID, BUYER, BigInt.fromI32(0), usdcRaw, tokensRaw)
    handleOutcomeBought(event)

    assert.fieldEquals('Market', CONDITION_ID.toHexString(), 'probability', '0.5')
  })

  test('creates User entity for buyer', () => {
    let usdcRaw   = BigInt.fromString('100000000')
    let tokensRaw = BigInt.fromString('200000000000000000000')
    let event     = createOutcomeBoughtEvent(CONDITION_ID, BUYER, BigInt.fromI32(0), usdcRaw, tokensRaw)
    handleOutcomeBought(event)

    assert.entityCount('User', 2) // CREATOR (from MarketCreated) + BUYER
    assert.fieldEquals('User', BUYER.toHexString(), 'tradeCount', '1')
    assert.fieldEquals('User', BUYER.toHexString(), 'totalVolume', '100')
  })
})

describe('handleMarketResolved', () => {
  beforeEach(() => {
    clearStore()
    let event = createMarketCreatedEvent(CONDITION_ID, CREATOR, QUESTION, IPFS_HASH, RES_TIME)
    handleMarketCreated(event)
  })
  afterEach(() => { clearStore() })

  test('sets status to Resolved with YES outcome', () => {
    let payouts = [BigInt.fromI32(1), BigInt.fromI32(0)]
    let event   = createMarketResolvedEvent(CONDITION_ID, payouts)
    handleMarketResolved(event)

    let marketId = CONDITION_ID.toHexString()
    assert.fieldEquals('Market', marketId, 'status', 'Resolved')
    assert.fieldEquals('Market', marketId, 'outcome', 'YES')
    assert.fieldEquals('Market', marketId, 'probability', '1')
  })

  test('sets status to Resolved with NO outcome', () => {
    let payouts = [BigInt.fromI32(0), BigInt.fromI32(1)]
    let event   = createMarketResolvedEvent(CONDITION_ID, payouts)
    handleMarketResolved(event)

    let marketId = CONDITION_ID.toHexString()
    assert.fieldEquals('Market', marketId, 'status', 'Resolved')
    assert.fieldEquals('Market', marketId, 'outcome', 'NO')
    assert.fieldEquals('Market', marketId, 'probability', '0')
  })

  test('sets INVALID outcome when both payouts are non-zero', () => {
    let payouts = [BigInt.fromI32(1), BigInt.fromI32(1)]
    let event   = createMarketResolvedEvent(CONDITION_ID, payouts)
    handleMarketResolved(event)

    assert.fieldEquals('Market', CONDITION_ID.toHexString(), 'outcome', 'INVALID')
  })

  test('updates Protocol resolvedMarkets count', () => {
    let payouts = [BigInt.fromI32(1), BigInt.fromI32(0)]
    let event   = createMarketResolvedEvent(CONDITION_ID, payouts)
    handleMarketResolved(event)

    assert.fieldEquals('Protocol', 'fluxmarkets', 'resolvedMarkets', '1')
  })
})

describe('handlePositionsRedeemed', () => {
  beforeEach(() => {
    clearStore()
    // Create market
    let mktEvent = createMarketCreatedEvent(CONDITION_ID, CREATOR, QUESTION, IPFS_HASH, RES_TIME)
    handleMarketCreated(mktEvent)
    // Buy position: 500 YES tokens for $250
    let buyEvent = createOutcomeBoughtEvent(
      CONDITION_ID, BUYER,
      BigInt.fromI32(0),
      BigInt.fromString('250000000'),
      BigInt.fromString('500000000000000000000')
    )
    handleOutcomeBought(buyEvent)
    // Resolve YES
    let resolveEvent = createMarketResolvedEvent(CONDITION_ID, [BigInt.fromI32(1), BigInt.fromI32(0)])
    handleMarketResolved(resolveEvent)
  })
  afterEach(() => { clearStore() })

  test('updates Position realizedPnl and zeroes shares', () => {
    // Redeem $500 (2x return on $250 investment)
    let payoutRaw = BigInt.fromString('500000000') // $500
    let event     = createPositionsRedeemedEvent(CONDITION_ID, BUYER, payoutRaw)
    handlePositionsRedeemed(event)

    let posId = CONDITION_ID.toHexString() + '-' + BUYER.toHexString()
    assert.fieldEquals('Position', posId, 'yesShares', '0')
    assert.fieldEquals('Position', posId, 'noShares', '0')
    // realizedPnl = payout - costBasis = 500 - (0.5 * 500) = 500 - 250 = 250
    assert.fieldEquals('Position', posId, 'realizedPnl', '250')
  })

  test('updates User realizedPnl', () => {
    let payoutRaw = BigInt.fromString('500000000')
    let event     = createPositionsRedeemedEvent(CONDITION_ID, BUYER, payoutRaw)
    handlePositionsRedeemed(event)

    assert.fieldEquals('User', BUYER.toHexString(), 'realizedPnl', '250')
  })
})
