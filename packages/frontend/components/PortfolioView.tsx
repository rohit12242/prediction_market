'use client'

import { useAccount } from 'wagmi'
import { useQuery } from '@tanstack/react-query'
import { gqlClient } from '@/lib/gqlClient'
import { gql } from 'graphql-request'
import Link from 'next/link'

const POSITIONS_QUERY = gql`
  query Positions($trader: String!) {
    positions(trader: $trader) {
      id
      marketId
      yesShares
      noShares
      totalInvested
      realizedPnl
    }
  }
`

interface Position {
  id: string
  marketId: string
  yesShares: string
  noShares: string
  totalInvested: string
  realizedPnl: string
}

function usePositions(trader: string | undefined) {
  return useQuery({
    queryKey: ['positions', trader],
    queryFn: () =>
      gqlClient
        .request<{ positions: Position[] }>(POSITIONS_QUERY, { trader })
        .then((d) => d.positions),
    enabled: !!trader,
  })
}

export function PortfolioView() {
  const { address, isConnected } = useAccount()
  const { data: positions, isLoading } = usePositions(address)

  if (!isConnected) {
    return (
      <div className="rounded-xl border border-gray-800 p-12 text-center text-gray-400">
        Connect your wallet to view your portfolio.
      </div>
    )
  }

  return (
    <div>
      <h1 className="mb-6 text-3xl font-bold text-white">Portfolio</h1>
      <p className="mb-6 text-sm text-gray-500 font-mono">{address}</p>

      {isLoading ? (
        <div className="space-y-3">
          {Array.from({ length: 3 }).map((_, i) => (
            <div key={i} className="h-20 animate-pulse rounded-xl bg-gray-800" />
          ))}
        </div>
      ) : !positions?.length ? (
        <div className="rounded-xl border border-gray-800 p-12 text-center text-gray-500">
          No open positions.{' '}
          <Link href="/" className="text-brand-500 hover:underline">
            Browse markets
          </Link>
        </div>
      ) : (
        <div className="overflow-hidden rounded-xl border border-gray-800">
          <table className="w-full text-sm">
            <thead className="border-b border-gray-800 bg-gray-900 text-gray-500">
              <tr>
                <th className="px-4 py-3 text-left">Market</th>
                <th className="px-4 py-3 text-right">Yes Shares</th>
                <th className="px-4 py-3 text-right">No Shares</th>
                <th className="px-4 py-3 text-right">Invested</th>
                <th className="px-4 py-3 text-right">Realized P&L</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-800">
              {positions.map((pos) => {
                const pnl = parseFloat(pos.realizedPnl)
                return (
                  <tr key={pos.id} className="bg-gray-900 hover:bg-gray-800 transition-colors">
                    <td className="px-4 py-3">
                      <Link
                        href={`/markets/${pos.marketId}`}
                        className="text-brand-400 hover:underline"
                      >
                        #{pos.marketId}
                      </Link>
                    </td>
                    <td className="px-4 py-3 text-right text-yes">{pos.yesShares}</td>
                    <td className="px-4 py-3 text-right text-no">{pos.noShares}</td>
                    <td className="px-4 py-3 text-right text-gray-300">{pos.totalInvested}</td>
                    <td
                      className={`px-4 py-3 text-right font-medium ${
                        pnl >= 0 ? 'text-yes' : 'text-no'
                      }`}
                    >
                      {pnl >= 0 ? '+' : ''}
                      {pos.realizedPnl}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
