'use client'

import Link from 'next/link'
import type { Market } from '@/hooks/useMarkets'

export function MarketCard({ market }: { market: Market }) {
  const yesPercent = Math.round((market.yesPrice ?? 0.5) * 100)
  const noPercent = 100 - yesPercent

  return (
    <Link
      href={`/markets/${market.id}`}
      className="group flex flex-col rounded-xl border border-gray-800 bg-gray-900 p-5 transition-all hover:border-gray-600 hover:bg-gray-850"
    >
      <p className="line-clamp-3 flex-1 text-sm font-medium text-gray-100 group-hover:text-white">
        {market.question}
      </p>

      <div className="mt-4 space-y-2">
        {/* Probability bar */}
        <div className="flex h-2 overflow-hidden rounded-full bg-gray-700">
          <div className="bg-yes" style={{ width: `${yesPercent}%` }} />
          <div className="bg-no flex-1" />
        </div>

        <div className="flex justify-between text-xs text-gray-400">
          <span className="font-medium text-yes">{yesPercent}% Yes</span>
          <span className="font-medium text-no">{noPercent}% No</span>
        </div>

        <div className="flex items-center justify-between pt-1 text-xs text-gray-500">
          <span>Liquidity: {market.totalLiquidity}</span>
          {market.resolved && (
            <span className="rounded-full bg-gray-700 px-2 py-0.5 text-gray-300">Resolved</span>
          )}
        </div>
      </div>
    </Link>
  )
}
