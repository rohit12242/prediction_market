'use client'

import { useState } from 'react'
import { useAccount } from 'wagmi'
import { useBuyShares } from '@/hooks/useContract'

export function TradePanel({ marketId }: { marketId: string }) {
  const { isConnected } = useAccount()
  const [isYes, setIsYes] = useState(true)
  const [amount, setAmount] = useState('')
  const { mutate: buyShares, isPending } = useBuyShares()

  const handleTrade = () => {
    if (!amount || isNaN(Number(amount))) return
    buyShares({ marketId: BigInt(marketId), isYes, amount })
  }

  if (!isConnected) {
    return (
      <div className="rounded-xl border border-gray-800 p-6 text-center text-gray-400">
        Connect your wallet to trade.
      </div>
    )
  }

  return (
    <div className="rounded-xl border border-gray-800 bg-gray-900 p-6 space-y-4">
      <h2 className="font-semibold text-white">Place a Trade</h2>

      <div className="flex rounded-lg overflow-hidden border border-gray-700">
        <button
          onClick={() => setIsYes(true)}
          className={`flex-1 py-2 text-sm font-medium transition-colors ${
            isYes ? 'bg-yes text-white' : 'text-gray-400 hover:text-white'
          }`}
        >
          Yes
        </button>
        <button
          onClick={() => setIsYes(false)}
          className={`flex-1 py-2 text-sm font-medium transition-colors ${
            !isYes ? 'bg-no text-white' : 'text-gray-400 hover:text-white'
          }`}
        >
          No
        </button>
      </div>

      <div>
        <label className="mb-1 block text-xs text-gray-500">Amount (USDC)</label>
        <input
          type="number"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          placeholder="0.00"
          className="w-full rounded-lg border border-gray-700 bg-gray-800 px-3 py-2 text-white placeholder-gray-600 focus:border-brand-500 focus:outline-none"
        />
      </div>

      <button
        onClick={handleTrade}
        disabled={isPending || !amount}
        className="w-full rounded-lg bg-brand-600 py-2.5 text-sm font-semibold text-white hover:bg-brand-500 disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
      >
        {isPending ? 'Confirming…' : `Buy ${isYes ? 'Yes' : 'No'}`}
      </button>
    </div>
  )
}
