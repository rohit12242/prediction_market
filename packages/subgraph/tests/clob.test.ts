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
  OrderPlaced,
  OrderFilled,
  OrderPartiallyFilled,
  OrderCancelled,
  TradeExecuted
} from '../generated/templates/CLOBOrderBook/CLOBOrderBook'
import {
  handleOrderPlaced,
  handleOrderFilled,
  handleOrderPartiallyFilled,
  handleOrderCancelled,
  handleTradeExecuted
} from '../src/clob'
import { Market, CLOBMarketLink } from '../generated/schema'
import { ZERO_BD, ZERO_BI, HALF_BD } from '../src/helpers'

// ── Constants ────────────────────────────────────────────────────────────────

const CONDITION_ID = Bytes.fromHexString(
  '0xbbbb000000000000000000000000000000000000000000000000000000000002'
)
const CLOB_ADDR = Address.fromString('0xCCCC000000000000000000000000000000000001')
const BUYER     = Address.fromString('0xAAAA000000000000000000000000000000000001')
const SELLER    = Address.fromString('0xBBBB000000000000000000000000000000000002')

const ORDER_ID_BUY  = Bytes.fromHexString('0x0101010101010101010101010101010101010101010101010101010101010101')
const ORDER_ID_SELL = Bytes.fromHexString('0x0202020202020202020202020202020202020202020202020202020202020202')

// ── Setup helpers ────────────────────────────────────────────────────────────

// Creates a Market entity and a CLOBMarketLink so CLOB handlers can find the market.
function setupMarketAndCLOBLink(): void {
  let marketId = CONDITION_ID.toHexString()
  let market   = new Market(marketId)
  market.question          = 'Test CLOB market?'
  market.description       = ''
  market.category          = 'other'
  market.ipfsHash          = ''
  market.dataIpfsHash      = ''
  market.creator           = BUYER
  market.createdAt         = BigInt.fromI32(1000000)
  market.createdAtBlock    = BigInt.fromI32(1)
  market.resolutionTime    = BigInt.fromI32(1893456000)
  market.status            = 'Active'
  market.payouts           = []
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
  market.save()

  let link = new CLOBMarketLink(CLOB_ADDR.toHexString())
  link.conditionId = CONDITION_ID
  link.market      = marketId
  link.save()
}

// ── Event factory helpers ────────────────────────────────────────────────────

function createOrderPlacedEvent(
  orderId: Bytes,
  trader: Address,
  side: i32,
  outcomeIndex: BigInt,
  price: BigInt,
  amount: BigInt
): OrderPlaced {
  let mockEvent = changetype<OrderPlaced>(newMockEvent())
  mockEvent.address = CLOB_ADDR
  mockEvent.parameters = []
  mockEvent.parameters.push(new ethereum.EventParam('orderId',      ethereum.Value.fromFixedBytes(orderId)))
  mockEvent.parameters.push(new ethereum.EventParam('trader',       ethereum.Value.fromAddress(trader)))
  mockEvent.parameters.push(new ethereum.EventParam('side',         ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(side))))
  mockEvent.parameters.push(new ethereum.EventParam('outcomeIndex', ethereum.Value.fromUnsignedBigInt(outcomeIndex)))
  mockEvent.parameters.push(new ethereum.EventParam('price',        ethereum.Value.fromUnsignedBigInt(price)))
  mockEvent.parameters.push(new ethereum.EventParam('amount',       ethereum.Value.fromUnsignedBigInt(amount)))
  return mockEvent
}

function createOrderFilledEvent(
  orderId: Bytes,
  matchedOrderId: Bytes,
  trader: Address,
  filledAmount: BigInt,
  price: BigInt
): OrderFilled {
  let mockEvent = changetype<OrderFilled>(newMockEvent())
  mockEvent.address = CLOB_ADDR
  mockEvent.parameters = []
  mockEvent.parameters.push(new ethereum.EventParam('orderId',        ethereum.Value.fromFixedBytes(orderId)))
  mockEvent.parameters.push(new ethereum.EventParam('matchedOrderId', ethereum.Value.fromFixedBytes(matchedOrderId)))
  mockEvent.parameters.push(new ethereum.EventParam('trader',         ethereum.Value.fromAddress(trader)))
  mockEvent.parameters.push(new ethereum.EventParam('filledAmount',   ethereum.Value.fromUnsignedBigInt(filledAmount)))
  mockEvent.parameters.push(new ethereum.EventParam('price',          ethereum.Value.fromUnsignedBigInt(price)))
  return mockEvent
}

function createOrderPartiallyFilledEvent(
  orderId: Bytes,
  filledAmount: BigInt,
  remainingAmount: BigInt
): OrderPartiallyFilled {
  let mockEvent = changetype<OrderPartiallyFilled>(newMockEvent())
  mockEvent.address = CLOB_ADDR
  mockEvent.parameters = []
  mockEvent.parameters.push(new ethereum.EventParam('orderId',         ethereum.Value.fromFixedBytes(orderId)))
  mockEvent.parameters.push(new ethereum.EventParam('filledAmount',    ethereum.Value.fromUnsignedBigInt(filledAmount)))
  mockEvent.parameters.push(new ethereum.EventParam('remainingAmount', ethereum.Value.fromUnsignedBigInt(remainingAmount)))
  return mockEvent
}

function createOrderCancelledEvent(
  orderId: Bytes,
  trader: Address,
  refundAmount: BigInt
): OrderCancelled {
  let mockEvent = changetype<OrderCancelled>(newMockEvent())
  mockEvent.address = CLOB_ADDR
  mockEvent.parameters = []
  mockEvent.parameters.push(new ethereum.EventParam('orderId',      ethereum.Value.fromFixedBytes(orderId)))
  mockEvent.parameters.push(new ethereum.EventParam('trader',       ethereum.Value.fromAddress(trader)))
  mockEvent.parameters.push(new ethereum.EventParam('refundAmount', ethereum.Value.fromUnsignedBigInt(refundAmount)))
  return mockEvent
}

function createTradeExecutedEvent(
  buyOrderId: Bytes,
  sellOrderId: Bytes,
  outcomeIndex: BigInt,
  price: BigInt,
  amount: BigInt
): TradeExecuted {
  let mockEvent = changetype<TradeExecuted>(newMockEvent())
  mockEvent.address = CLOB_ADDR
  mockEvent.parameters = []
  mockEvent.parameters.push(new ethereum.EventParam('buyOrderId',   ethereum.Value.fromFixedBytes(buyOrderId)))
  mockEvent.parameters.push(new ethereum.EventParam('sellOrderId',  ethereum.Value.fromFixedBytes(sellOrderId)))
  mockEvent.parameters.push(new ethereum.EventParam('outcomeIndex', ethereum.Value.fromUnsignedBigInt(outcomeIndex)))
  mockEvent.parameters.push(new ethereum.EventParam('price',        ethereum.Value.fromUnsignedBigInt(price)))
  mockEvent.parameters.push(new ethereum.EventParam('amount',       ethereum.Value.fromUnsignedBigInt(amount)))
  return mockEvent
}

// ── Tests ────────────────────────────────────────────────────────────────────

describe('handleOrderPlaced', () => {
  beforeEach(() => {
    clearStore()
    setupMarketAndCLOBLink()
  })
  afterEach(() => { clearStore() })

  test('creates Order entity with status=Open for BUY side', () => {
    // price = 500000 (0.5), amount = 100 tokens (100e18)
    let price  = BigInt.fromString('500000')
    let amount = BigInt.fromString('100000000000000000000')
    let event  = createOrderPlacedEvent(ORDER_ID_BUY, BUYER, 0, BigInt.fromI32(0), price, amount)
    handleOrderPlaced(event)

    let orderId = ORDER_ID_BUY.toHexString()
    assert.entityCount('Order', 1)
    assert.fieldEquals('Order', orderId, 'status', 'Open')
    assert.fieldEquals('Order', orderId, 'side', 'BUY')
    assert.fieldEquals('Order', orderId, 'outcomeName', 'YES')
    assert.fieldEquals('Order', orderId, 'price', '0.5')
    assert.fieldEquals('Order', orderId, 'originalSize', '100')
    assert.fieldEquals('Order', orderId, 'remainingSize', '100')
    assert.fieldEquals('Order', orderId, 'filledSize', '0')
  })

  test('creates Order entity with status=Open for SELL side', () => {
    let price  = BigInt.fromString('600000') // 0.6
    let amount = BigInt.fromString('50000000000000000000') // 50 tokens
    let event  = createOrderPlacedEvent(ORDER_ID_SELL, SELLER, 1, BigInt.fromI32(1), price, amount)
    handleOrderPlaced(event)

    let orderId = ORDER_ID_SELL.toHexString()
    assert.fieldEquals('Order', orderId, 'status', 'Open')
    assert.fieldEquals('Order', orderId, 'side', 'SELL')
    assert.fieldEquals('Order', orderId, 'outcomeName', 'NO')
    assert.fieldEquals('Order', orderId, 'usdcCommitted', '0')
  })

  test('increments market orderCount', () => {
    let event = createOrderPlacedEvent(
      ORDER_ID_BUY, BUYER, 0, BigInt.fromI32(0),
      BigInt.fromString('500000'), BigInt.fromString('100000000000000000000')
    )
    handleOrderPlaced(event)

    assert.fieldEquals('Market', CONDITION_ID.toHexString(), 'orderCount', '1')
  })

  test('updates bestBid for BUY order', () => {
    let event = createOrderPlacedEvent(
      ORDER_ID_BUY, BUYER, 0, BigInt.fromI32(0),
      BigInt.fromString('450000'), BigInt.fromString('100000000000000000000')
    )
    handleOrderPlaced(event)

    assert.fieldEquals('Market', CONDITION_ID.toHexString(), 'bestBid', '0.45')
  })

  test('updates bestAsk for SELL order', () => {
    let event = createOrderPlacedEvent(
      ORDER_ID_SELL, SELLER, 1, BigInt.fromI32(0),
      BigInt.fromString('550000'), BigInt.fromString('100000000000000000000')
    )
    handleOrderPlaced(event)

    assert.fieldEquals('Market', CONDITION_ID.toHexString(), 'bestAsk', '0.55')
  })

  test('increments Protocol totalOrders', () => {
    let event = createOrderPlacedEvent(
      ORDER_ID_BUY, BUYER, 0, BigInt.fromI32(0),
      BigInt.fromString('500000'), BigInt.fromString('100000000000000000000')
    )
    handleOrderPlaced(event)

    assert.fieldEquals('Protocol', 'fluxmarkets', 'totalOrders', '1')
  })
})

describe('handleOrderPartiallyFilled', () => {
  beforeEach(() => {
    clearStore()
    setupMarketAndCLOBLink()
    // Place the order first
    let event = createOrderPlacedEvent(
      ORDER_ID_BUY, BUYER, 0, BigInt.fromI32(0),
      BigInt.fromString('500000'), BigInt.fromString('100000000000000000000')
    )
    handleOrderPlaced(event)
  })
  afterEach(() => { clearStore() })

  test('sets status to PartiallyFilled and updates sizes', () => {
    // Fill 40 tokens, 60 remaining
    let filledAmt    = BigInt.fromString('40000000000000000000')
    let remainingAmt = BigInt.fromString('60000000000000000000')
    let event        = createOrderPartiallyFilledEvent(ORDER_ID_BUY, filledAmt, remainingAmt)
    handleOrderPartiallyFilled(event)

    let orderId = ORDER_ID_BUY.toHexString()
    assert.fieldEquals('Order', orderId, 'status', 'PartiallyFilled')
    assert.fieldEquals('Order', orderId, 'filledSize', '40')
    assert.fieldEquals('Order', orderId, 'remainingSize', '60')
  })

  test('accumulates filledSize across multiple partial fills', () => {
    // First partial fill: 30 filled, 70 remaining
    handleOrderPartiallyFilled(
      createOrderPartiallyFilledEvent(
        ORDER_ID_BUY,
        BigInt.fromString('30000000000000000000'),
        BigInt.fromString('70000000000000000000')
      )
    )
    // Second partial fill: 20 more filled, 50 remaining
    handleOrderPartiallyFilled(
      createOrderPartiallyFilledEvent(
        ORDER_ID_BUY,
        BigInt.fromString('20000000000000000000'),
        BigInt.fromString('50000000000000000000')
      )
    )

    let orderId = ORDER_ID_BUY.toHexString()
    assert.fieldEquals('Order', orderId, 'filledSize', '50')
    assert.fieldEquals('Order', orderId, 'remainingSize', '50')
  })
})

describe('handleOrderCancelled', () => {
  beforeEach(() => {
    clearStore()
    setupMarketAndCLOBLink()
    let event = createOrderPlacedEvent(
      ORDER_ID_BUY, BUYER, 0, BigInt.fromI32(0),
      BigInt.fromString('500000'), BigInt.fromString('100000000000000000000')
    )
    handleOrderPlaced(event)
  })
  afterEach(() => { clearStore() })

  test('sets Order status to Cancelled', () => {
    let refundAmount = BigInt.fromString('50000000') // $50 refund
    let event        = createOrderCancelledEvent(ORDER_ID_BUY, BUYER, refundAmount)
    handleOrderCancelled(event)

    assert.fieldEquals('Order', ORDER_ID_BUY.toHexString(), 'status', 'Cancelled')
  })

  test('does not modify other Order fields on cancel', () => {
    let refundAmount = BigInt.fromString('50000000')
    let event        = createOrderCancelledEvent(ORDER_ID_BUY, BUYER, refundAmount)
    handleOrderCancelled(event)

    assert.fieldEquals('Order', ORDER_ID_BUY.toHexString(), 'originalSize', '100')
    assert.fieldEquals('Order', ORDER_ID_BUY.toHexString(), 'filledSize', '0')
  })
})

describe('handleTradeExecuted', () => {
  beforeEach(() => {
    clearStore()
    setupMarketAndCLOBLink()
    // Place buy order
    handleOrderPlaced(
      createOrderPlacedEvent(
        ORDER_ID_BUY, BUYER, 0, BigInt.fromI32(0),
        BigInt.fromString('500000'), BigInt.fromString('100000000000000000000')
      )
    )
    // Place sell order
    handleOrderPlaced(
      createOrderPlacedEvent(
        ORDER_ID_SELL, SELLER, 1, BigInt.fromI32(0),
        BigInt.fromString('500000'), BigInt.fromString('100000000000000000000')
      )
    )
  })
  afterEach(() => { clearStore() })

  test('creates Trade entity with source=CLOB', () => {
    // Trade: 100 YES tokens @ 0.5 → $50 volume
    let price  = BigInt.fromString('500000')               // 0.5
    let amount = BigInt.fromString('100000000000000000000') // 100 tokens
    let event  = createTradeExecutedEvent(ORDER_ID_BUY, ORDER_ID_SELL, BigInt.fromI32(0), price, amount)
    handleTradeExecuted(event)

    assert.entityCount('Trade', 1)
    let tradeId = event.transaction.hash.toHexString() + '-' + event.logIndex.toString()
    assert.fieldEquals('Trade', tradeId, 'source', 'CLOB')
    assert.fieldEquals('Trade', tradeId, 'outcomeName', 'YES')
    assert.fieldEquals('Trade', tradeId, 'price', '0.5')
    assert.fieldEquals('Trade', tradeId, 'size', '100')
    assert.fieldEquals('Trade', tradeId, 'usdcVolume', '50')
  })

  test('updates Market clobVolume and tradeCount', () => {
    let price  = BigInt.fromString('500000')
    let amount = BigInt.fromString('100000000000000000000')
    let event  = createTradeExecutedEvent(ORDER_ID_BUY, ORDER_ID_SELL, BigInt.fromI32(0), price, amount)
    handleTradeExecuted(event)

    let marketId = CONDITION_ID.toHexString()
    assert.fieldEquals('Market', marketId, 'clobVolume', '50')
    assert.fieldEquals('Market', marketId, 'totalVolume', '50')
    assert.fieldEquals('Market', marketId, 'tradeCount', '1')
  })

  test('updates Market lastTradePrice and probability for YES trade', () => {
    let price  = BigInt.fromString('700000') // 0.7
    let amount = BigInt.fromString('100000000000000000000')
    let event  = createTradeExecutedEvent(ORDER_ID_BUY, ORDER_ID_SELL, BigInt.fromI32(0), price, amount)
    handleTradeExecuted(event)

    let marketId = CONDITION_ID.toHexString()
    assert.fieldEquals('Market', marketId, 'lastTradePrice', '0.7')
    assert.fieldEquals('Market', marketId, 'probability', '0.7')
  })

  test('updates Market probability for NO trade (outcomeIndex=1)', () => {
    let price  = BigInt.fromString('300000') // 0.3 for NO → YES prob = 0.7
    let amount = BigInt.fromString('100000000000000000000')
    let event  = createTradeExecutedEvent(ORDER_ID_BUY, ORDER_ID_SELL, BigInt.fromI32(1), price, amount)
    handleTradeExecuted(event)

    // probability = 1 - 0.3 = 0.7
    assert.fieldEquals('Market', CONDITION_ID.toHexString(), 'probability', '0.7')
  })

  test('creates buyer and seller Position entities', () => {
    let price  = BigInt.fromString('500000')
    let amount = BigInt.fromString('100000000000000000000')
    let event  = createTradeExecutedEvent(ORDER_ID_BUY, ORDER_ID_SELL, BigInt.fromI32(0), price, amount)
    handleTradeExecuted(event)

    let buyerPosId  = CONDITION_ID.toHexString() + '-' + BUYER.toHexString()
    let sellerPosId = CONDITION_ID.toHexString() + '-' + SELLER.toHexString()

    assert.entityCount('Position', 2)
    assert.fieldEquals('Position', buyerPosId,  'yesShares', '100')
    assert.fieldEquals('Position', sellerPosId, 'yesShares', '0')
  })

  test('updates Protocol totalTrades', () => {
    let price  = BigInt.fromString('500000')
    let amount = BigInt.fromString('100000000000000000000')
    let event  = createTradeExecutedEvent(ORDER_ID_BUY, ORDER_ID_SELL, BigInt.fromI32(0), price, amount)
    handleTradeExecuted(event)

    assert.fieldEquals('Protocol', 'fluxmarkets', 'totalTrades', '1')
    assert.fieldEquals('Protocol', 'fluxmarkets', 'totalVolume', '50')
  })
})
