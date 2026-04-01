'use client'

import { useMarket } from '@/hooks/useMarkets'
import { TradePanel } from './TradePanel'

export function MarketDetail({ id }: { id: string }) {
  const { data: market, isLoading, error } = useMarket(id)

  if (isLoading) return <div className="h-96 animate-pulse rounded-xl bg-gray-800" />
  if (error || !market) return <div className="text-red-400">Market not found.</div>

  const yesPercent = Math.round((market.yesPrice ?? 0.5) * 100)

  return (
    <div className="grid grid-cols-1 gap-8 lg:grid-cols-3">
      <div className="lg:col-span-2 space-y-6">
        <div>
          <h1 className="text-2xl font-bold text-white">{market.question}</h1>
          {market.description && (
            <p className="mt-3 text-gray-400">{market.description}</p>
          )}
        </div>

        <div className="space-y-2">
          <div className="flex h-4 overflow-hidden rounded-full bg-gray-700">
            <div className="bg-yes transition-all" style={{ width: `${yesPercent}%` }} />
            <div className="bg-no flex-1" />
          </div>
          <div className="flex justify-between text-sm">
            <span className="font-semibold text-yes">{yesPercent}% Yes</span>
            <span className="font-semibold text-no">{100 - yesPercent}% No</span>
          </div>
        </div>

        <div className="grid grid-cols-2 gap-4 rounded-xl border border-gray-800 p-4 text-sm">
          <div>
            <p className="text-gray-500">Total Liquidity</p>
            <p className="mt-1 font-semibold text-white">{market.totalLiquidity}</p>
          </div>
          <div>
            <p className="text-gray-500">Status</p>
            <p className="mt-1 font-semibold text-white">
              {market.resolved ? `Resolved: ${market.outcome}` : 'Open'}
            </p>
          </div>
        </div>
      </div>

      {!market.resolved && (
        <div>
          <TradePanel marketId={id} />
        </div>
      )}
    </div>
  )
}
