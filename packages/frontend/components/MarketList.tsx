'use client'

import { useMarkets } from '@/hooks/useMarkets'
import { MarketCard } from './MarketCard'

export function MarketList() {
  const { data: markets, isLoading, error } = useMarkets()

  if (isLoading) {
    return (
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {Array.from({ length: 6 }).map((_, i) => (
          <div key={i} className="h-48 animate-pulse rounded-xl bg-gray-800" />
        ))}
      </div>
    )
  }

  if (error) {
    return (
      <div className="rounded-xl border border-red-800 bg-red-950 p-6 text-red-400">
        Failed to load markets. Is the backend running?
      </div>
    )
  }

  if (!markets?.length) {
    return (
      <div className="rounded-xl border border-gray-800 p-12 text-center text-gray-500">
        No markets yet.
      </div>
    )
  }

  return (
    <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
      {markets.map((market) => (
        <MarketCard key={market.id} market={market} />
      ))}
    </div>
  )
}
