import { useState, useEffect } from 'react'
import { Receipt } from 'lucide-react'
import { PageShell } from '../components/PageShell'
import { sbFetchAuth } from '../supabase'

export default function MyBetsPage() {
  return (
    <PageShell title="My Bets" requireAuth>
      {session => <MyBetsContent session={session} />}
    </PageShell>
  )
}

function MyBetsContent({ session }) {
  const [bets, setBets] = useState([])
  const [loading, setLoading] = useState(true)
  const userId = session.user.id

  useEffect(() => {
    sbFetchAuth(
      `bets?user_id=eq.${userId}&select=amount,position,status,created_at,markets(creator_id,timeframe,end_at,profiles(username))&order=created_at.desc&limit=30`,
      session,
    ).then(data => {
      setBets(Array.isArray(data) ? data : [])
      setLoading(false)
    }).catch(() => setLoading(false))
  }, [userId])

  if (loading) return <SkeletonLoader />

  const statusColor = s => ({ won: '#00C896', lost: '#FF4757', refunded: '#8B8FA8' }[s] ?? '#6C63FF')
  const statusLabel = s => ({ won: 'Won', lost: 'Lost', refunded: 'Refunded' }[s] ?? 'Active')
  const posLabel = p => p === 'yes' ? '📈 Will Increase' : '📉 Will Decrease'
  const posColor = p => p === 'yes' ? '#00C896' : '#FF4757'
  const tfLabel = t => ({ '15m': '15 min', '1h': '1 Hour', '4h': '4 Hours', '24h': '1 Day' }[t] ?? t)

  return (
    <div style={{ padding: '24px 20px', maxWidth: 480, margin: '0 auto', width: '100%' }}>
      {bets.length === 0 ? (
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', padding: '64px 0', gap: 12, color: '#8B8FA8' }}>
          <Receipt size={48} />
          <div style={{ fontSize: 18, fontWeight: 700, color: 'white' }}>No bets yet</div>
          <div style={{ fontSize: 14 }}>Find a creator to bet on</div>
          <a href="/markets" style={{ marginTop: 8, backgroundColor: '#6C63FF', borderRadius: 10, padding: '12px 24px', color: 'white', fontWeight: 700, textDecoration: 'none' }}>Browse Markets</a>
        </div>
      ) : (
        <>
          {bets.map((bet, i) => {
            const creator = bet.markets?.profiles?.username ?? '—'
            const sc = statusColor(bet.status)
            return (
              <div key={i} style={{ backgroundColor: '#1A1A2E', border: '1px solid #2A2A3E', borderRadius: 14, padding: 16, marginBottom: 12 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 8 }}>
                  <div>
                    <div style={{ fontSize: 15, fontWeight: 700, color: 'white' }}>@{creator}</div>
                    <div style={{ fontSize: 12, color: '#8B8FA8', marginTop: 2 }}>{tfLabel(bet.markets?.timeframe)} market</div>
                  </div>
                  <span style={{ fontSize: 11, fontWeight: 700, color: sc, backgroundColor: sc + '1F', border: `1px solid ${sc}59`, borderRadius: 8, padding: '3px 9px' }}>
                    {statusLabel(bet.status)}
                  </span>
                </div>
                <div style={{ height: 1, backgroundColor: '#2A2A3E', margin: '10px 0' }} />
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <div>
                    <div style={{ fontSize: 11, color: '#8B8FA8', marginBottom: 2 }}>Position</div>
                    <div style={{ fontSize: 13, fontWeight: 600, color: posColor(bet.position) }}>{posLabel(bet.position)}</div>
                  </div>
                  <div style={{ textAlign: 'center' }}>
                    <div style={{ fontSize: 11, color: '#8B8FA8', marginBottom: 2 }}>Amount</div>
                    <div style={{ fontSize: 13, fontWeight: 600, color: 'white' }}>{bet.amount} tokens</div>
                  </div>
                  <div style={{ textAlign: 'right' }}>
                    <div style={{ fontSize: 11, color: '#8B8FA8', marginBottom: 2 }}>Date</div>
                    <div style={{ fontSize: 12, color: '#8B8FA8' }}>{new Date(bet.created_at).toLocaleDateString()}</div>
                  </div>
                </div>
              </div>
            )
          })}
          <OpenInApp path="/markets/mybets" />
        </>
      )}
    </div>
  )
}

function SkeletonLoader() {
  return (
    <div style={{ padding: 24 }}>
      {[1,2,3].map(i => <div key={i} style={{ height: 110, backgroundColor: '#1A1A2E', borderRadius: 14, marginBottom: 12, opacity: 0.6 }} />)}
    </div>
  )
}

function OpenInApp({ path }) {
  return (
    <a href={path} style={{ display: 'block', textAlign: 'center', backgroundColor: '#6C63FF', borderRadius: 12, padding: '14px', color: 'white', fontWeight: 700, fontSize: 15, textDecoration: 'none', marginTop: 4, transition: 'background-color 0.15s' }}
      onMouseEnter={e => e.currentTarget.style.backgroundColor = '#7B73FF'}
      onMouseLeave={e => e.currentTarget.style.backgroundColor = '#6C63FF'}
    >
      Open Full View in App →
    </a>
  )
}
