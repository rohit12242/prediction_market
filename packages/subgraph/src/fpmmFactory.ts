import { FPMMCreated } from '../generated/FPMMFactory/FPMMFactory'
import { FixedProductMarketMaker as FPMMTemplate } from '../generated/templates'
import { FPMMMarketLink, Market } from '../generated/schema'

export function handleFPMMCreated(event: FPMMCreated): void {
  let conditionId = event.params.conditionId.toHexString()

  // Create the dynamic data source to index this FPMM instance
  FPMMTemplate.create(event.params.fpmm)

  // Store the link so FPMM handlers can find the market
  let link = new FPMMMarketLink(event.params.fpmm.toHexString())
  link.conditionId = event.params.conditionId
  link.market      = conditionId
  link.save()

  // Update the market with the FPMM address
  let market = Market.load(conditionId)
  if (market != null) {
    market.fpmmAddress = event.params.fpmm
    market.save()
  }
}
