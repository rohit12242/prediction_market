import type { Metadata } from 'next'
import './globals.css'
import { Providers } from '@/components/Providers'
import { Nav } from '@/components/Nav'

export const metadata: Metadata = {
  title: 'FluxMarkets — Decentralized Prediction Markets',
  description: 'Trade on real-world outcomes with FluxMarkets',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className="h-full bg-gray-950 text-gray-100">
      <body className="h-full antialiased">
        <Providers>
          <Nav />
          <main className="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-8">{children}</main>
        </Providers>
      </body>
    </html>
  )
}
