'use client'

import Link from 'next/link'
import { ConnectButton } from './ConnectButton'

export function Nav() {
  return (
    <nav className="border-b border-gray-800 bg-gray-950">
      <div className="mx-auto flex max-w-7xl items-center justify-between px-4 py-4 sm:px-6 lg:px-8">
        <Link href="/" className="text-xl font-bold text-brand-500">
          FluxMarkets
        </Link>
        <div className="flex items-center gap-6">
          <Link href="/" className="text-sm text-gray-400 hover:text-white transition-colors">
            Markets
          </Link>
          <Link href="/portfolio" className="text-sm text-gray-400 hover:text-white transition-colors">
            Portfolio
          </Link>
          <ConnectButton />
        </div>
      </div>
    </nav>
  )
}
