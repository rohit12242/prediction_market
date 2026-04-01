'use client'

import { useMutation } from '@tanstack/react-query'
import { useWriteContract } from 'wagmi'
import { parseUnits } from 'viem'
import { PREDICTION_MARKET_ABI } from '@/lib/abis'

const PREDICTION_MARKET_ADDRESS = process.env
  .NEXT_PUBLIC_PREDICTION_MARKET_ADDRESS as `0x${string}` | undefined

export function useBuyShares() {
  const { writeContractAsync } = useWriteContract()

  return useMutation({
    mutationFn: async ({
      marketId,
      isYes,
      amount,
    }: {
      marketId: bigint
      isYes: boolean
      amount: string
    }) => {
      if (!PREDICTION_MARKET_ADDRESS) throw new Error('Contract address not configured')
      const amountWei = parseUnits(amount, 18)
      const hash = await writeContractAsync({
        address: PREDICTION_MARKET_ADDRESS,
        abi: PREDICTION_MARKET_ABI,
        functionName: 'buyShares',
        args: [marketId, isYes, amountWei],
      })
      return hash
    },
  })
}
