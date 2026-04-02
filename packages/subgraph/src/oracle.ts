import {
  AssertionInitiated, AssertionSettled, AssertionDisputed
} from '../generated/UMAOracleAdapter/UMAOracleAdapter'
import { OracleAssertion, Market } from '../generated/schema'
import { ZERO_BI } from './helpers'

export function handleAssertionInitiated(event: AssertionInitiated): void {
  let conditionId = event.params.conditionId.toHexString()
  let market = Market.load(conditionId)
  if (market == null) return

  let id        = event.params.assertionId.toHexString()
  let assertion = new OracleAssertion(id)
  assertion.market         = market.id
  assertion.assertionId    = event.params.assertionId
  assertion.claimedOutcome = event.params.claimedOutcome
  assertion.asserter       = event.params.asserter
  assertion.disputed       = false
  assertion.settled        = false
  assertion.initiatedAt    = event.block.timestamp
  assertion.txHash         = event.transaction.hash
  assertion.save()

  market.status = 'PendingResolution'
  market.save()
}

export function handleAssertionSettled(event: AssertionSettled): void {
  let id        = event.params.assertionId.toHexString()
  let assertion = OracleAssertion.load(id)
  if (assertion == null) return

  assertion.settled   = true
  assertion.result    = event.params.result
  assertion.settledAt = event.block.timestamp
  assertion.save()
}

export function handleAssertionDisputed(event: AssertionDisputed): void {
  let id        = event.params.assertionId.toHexString()
  let assertion = OracleAssertion.load(id)
  if (assertion == null) return

  assertion.disputed = true
  assertion.disputer = event.params.disputer
  assertion.save()

  let market = Market.load(event.params.conditionId.toHexString())
  if (market != null) {
    market.status = 'Active'
    market.save()
  }
}
