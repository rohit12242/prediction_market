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
import { MarketDeployed } from '../generated/MarketFactory/MarketFactory'
import { handleMarketDeployed } from '../src/marketFactory'

// Helper to build a MarketDeployed mock event
function createMarketDeployedEvent(
  conditionId: Bytes,
  creator: Address,
  question: string,
  dataIpfsHash: string,
  resolutionTime: BigInt
): MarketDeployed {
  let mockEvent = changetype<MarketDeployed>(newMockEvent())

  mockEvent.parameters = []
  mockEvent.parameters.push(new ethereum.EventParam('conditionId',    ethereum.Value.fromFixedBytes(conditionId)))
  mockEvent.parameters.push(new ethereum.EventParam('creator',        ethereum.Value.fromAddress(creator)))
  mockEvent.parameters.push(new ethereum.EventParam('question',       ethereum.Value.fromString(question)))
  mockEvent.parameters.push(new ethereum.EventParam('dataIpfsHash',   ethereum.Value.fromString(dataIpfsHash)))
  mockEvent.parameters.push(new ethereum.EventParam('resolutionTime', ethereum.Value.fromUnsignedBigInt(resolutionTime)))

  return mockEvent
}

describe('handleMarketDeployed', () => {
  beforeEach(() => {
    clearStore()
  })

  afterEach(() => {
    clearStore()
  })

  test('creates Market entity with correct fields', () => {
    let conditionId    = Bytes.fromHexString('0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef')
    let creator        = Address.fromString('0xabcdef1234567890abcdef1234567890abcdef12')
    let question       = 'Will Bitcoin exceed $100k by end of 2026?'
    let dataIpfsHash   = 'QmTestHash123'
    let resolutionTime = BigInt.fromI32(1893456000)

    let event = createMarketDeployedEvent(conditionId, creator, question, dataIpfsHash, resolutionTime)
    handleMarketDeployed(event)

    let marketId = conditionId.toHexString()

    assert.entityCount('Market', 1)
    assert.fieldEquals('Market', marketId, 'question', question)
    assert.fieldEquals('Market', marketId, 'dataIpfsHash', dataIpfsHash)
    assert.fieldEquals('Market', marketId, 'status', 'Active')
    assert.fieldEquals('Market', marketId, 'creator', creator.toHexString())
    assert.fieldEquals('Market', marketId, 'resolutionTime', resolutionTime.toString())
  })

  test('detects crypto category from question', () => {
    let conditionId    = Bytes.fromHexString('0xaabbccdd1234567890abcdef1234567890abcdef1234567890abcdef12345678')
    let creator        = Address.fromString('0x1111111111111111111111111111111111111111')
    let question       = 'Will Ethereum merge happen successfully?'
    let dataIpfsHash   = 'QmEthHash'
    let resolutionTime = BigInt.fromI32(1893456000)

    let event = createMarketDeployedEvent(conditionId, creator, question, dataIpfsHash, resolutionTime)
    handleMarketDeployed(event)

    assert.fieldEquals('Market', conditionId.toHexString(), 'category', 'crypto')
  })

  test('detects politics category from question', () => {
    let conditionId    = Bytes.fromHexString('0xdeadbeef1234567890abcdef1234567890abcdef1234567890abcdef12345678')
    let creator        = Address.fromString('0x2222222222222222222222222222222222222222')
    let question       = 'Will the election results be certified?'
    let dataIpfsHash   = 'QmPolHash'
    let resolutionTime = BigInt.fromI32(1893456000)

    let event = createMarketDeployedEvent(conditionId, creator, question, dataIpfsHash, resolutionTime)
    handleMarketDeployed(event)

    assert.fieldEquals('Market', conditionId.toHexString(), 'category', 'politics')
  })

  test('detects sports category from question', () => {
    let conditionId    = Bytes.fromHexString('0xcafebabe1234567890abcdef1234567890abcdef1234567890abcdef12345678')
    let creator        = Address.fromString('0x3333333333333333333333333333333333333333')
    let question       = 'Will the NBA championship be won by Lakers?'
    let dataIpfsHash   = 'QmSportHash'
    let resolutionTime = BigInt.fromI32(1893456000)

    let event = createMarketDeployedEvent(conditionId, creator, question, dataIpfsHash, resolutionTime)
    handleMarketDeployed(event)

    assert.fieldEquals('Market', conditionId.toHexString(), 'category', 'sports')
  })

  test('defaults to other category for unrecognized question', () => {
    let conditionId    = Bytes.fromHexString('0x1111111111111111111111111111111111111111111111111111111111111111')
    let creator        = Address.fromString('0x4444444444444444444444444444444444444444')
    let question       = 'Will it rain in Tokyo tomorrow?'
    let dataIpfsHash   = 'QmOtherHash'
    let resolutionTime = BigInt.fromI32(1893456000)

    let event = createMarketDeployedEvent(conditionId, creator, question, dataIpfsHash, resolutionTime)
    handleMarketDeployed(event)

    assert.fieldEquals('Market', conditionId.toHexString(), 'category', 'other')
  })

  test('increments Protocol totalMarkets', () => {
    let conditionId    = Bytes.fromHexString('0x2222222222222222222222222222222222222222222222222222222222222222')
    let creator        = Address.fromString('0x5555555555555555555555555555555555555555')
    let question       = 'Test market?'
    let dataIpfsHash   = 'QmProtoHash'
    let resolutionTime = BigInt.fromI32(1893456000)

    let event = createMarketDeployedEvent(conditionId, creator, question, dataIpfsHash, resolutionTime)
    handleMarketDeployed(event)

    assert.entityCount('Protocol', 1)
    assert.fieldEquals('Protocol', 'fluxmarkets', 'totalMarkets', '1')
    assert.fieldEquals('Protocol', 'fluxmarkets', 'activeMarkets', '1')
  })

  test('increments Protocol totalMarkets for each market', () => {
    let conditionId1 = Bytes.fromHexString('0x3333333333333333333333333333333333333333333333333333333333333333')
    let conditionId2 = Bytes.fromHexString('0x4444444444444444444444444444444444444444444444444444444444444444')
    let creator      = Address.fromString('0x6666666666666666666666666666666666666666')

    let event1 = createMarketDeployedEvent(conditionId1, creator, 'Market 1?', 'QmHash1', BigInt.fromI32(1893456000))
    let event2 = createMarketDeployedEvent(conditionId2, creator, 'Market 2?', 'QmHash2', BigInt.fromI32(1893456001))
    handleMarketDeployed(event1)
    handleMarketDeployed(event2)

    assert.entityCount('Market', 2)
    assert.fieldEquals('Protocol', 'fluxmarkets', 'totalMarkets', '2')
    assert.fieldEquals('Protocol', 'fluxmarkets', 'activeMarkets', '2')
  })

  test('creates User entity for creator', () => {
    let conditionId    = Bytes.fromHexString('0x5555555555555555555555555555555555555555555555555555555555555555')
    let creator        = Address.fromString('0x7777777777777777777777777777777777777777')
    let question       = 'Will AI replace programmers?'
    let dataIpfsHash   = 'QmUserHash'
    let resolutionTime = BigInt.fromI32(1893456000)

    let event = createMarketDeployedEvent(conditionId, creator, question, dataIpfsHash, resolutionTime)
    handleMarketDeployed(event)

    assert.entityCount('User', 1)
    assert.fieldEquals('User', creator.toHexString(), 'marketsCreated', '1')
  })
})
