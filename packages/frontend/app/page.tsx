import { MarketList } from '@/components/MarketList'

export default function HomePage() {
  return (
    <div>
      <section className="mb-10">
        <h1 className="text-4xl font-bold tracking-tight text-white">
          Prediction Markets
        </h1>
        <p className="mt-3 text-lg text-gray-400">
          Trade on the outcomes of real-world events. Powered by FluxMarkets.
        </p>
      </section>
      <MarketList />
    </div>
  )
}
