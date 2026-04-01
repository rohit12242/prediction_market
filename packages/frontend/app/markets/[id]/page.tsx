import { MarketDetail } from '@/components/MarketDetail'

export default function MarketPage({ params }: { params: { id: string } }) {
  return <MarketDetail id={params.id} />
}
