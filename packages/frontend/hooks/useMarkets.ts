import { useQuery } from '@tanstack/react-query'
import { gqlClient } from '@/lib/gqlClient'
import { gql } from 'graphql-request'

export interface Market {
  id: string
  question: string
  description?: string
  yesPrice: number
  noPrice: number
  totalLiquidity: string
  resolved: boolean
  outcome: 'UNRESOLVED' | 'YES' | 'NO' | 'INVALID'
  endTime: string
  resolutionTime?: string
}

interface MarketsResponse {
  markets: Market[]
}

interface MarketResponse {
  market: Market | null
}

const MARKETS_QUERY = gql`
  query Markets($limit: Int, $offset: Int) {
    markets(limit: $limit, offset: $offset) {
      id
      question
      yesPrice
      noPrice
      totalLiquidity
      resolved
      outcome
      endTime
    }
  }
`

const MARKET_QUERY = gql`
  query Market($id: ID!) {
    market(id: $id) {
      id
      question
      description
      yesPrice
      noPrice
      totalLiquidity
      resolved
      outcome
      endTime
      resolutionTime
    }
  }
`

export function useMarkets(limit = 20, offset = 0) {
  return useQuery({
    queryKey: ['markets', limit, offset],
    queryFn: () =>
      gqlClient.request<MarketsResponse>(MARKETS_QUERY, { limit, offset }).then((d) => d.markets),
  })
}

export function useMarket(id: string) {
  return useQuery({
    queryKey: ['market', id],
    queryFn: () =>
      gqlClient.request<MarketResponse>(MARKET_QUERY, { id }).then((d) => d.market),
    enabled: !!id,
  })
}
