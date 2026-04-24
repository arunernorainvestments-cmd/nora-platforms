import { useState, useEffect } from 'react'
import { TrendingUp } from 'lucide-react'
import { PageShell } from '../components/PageShell'
import { sbFetchAuth } from '../supabase'

export default function DashboardPage() {
  return (
    <PageShell title="Score Dashboard" requireAuth>
      {session => <DashboardContent session={session} />}
    </PageShell>
  )
}

function DashboardContent({ session }) {
  const [metrics, setMetrics] = useState([])
  const [loading, setLoading] = useState(true)
  const userId = session.user.id

  useEffect(() => {
    sbFetchAuth(
      `platform_metrics?user_id=eq.${userId}&select=platform,heat_score,display_score,resolution_score,live_viewer_count,follower_count,is_live,updated_at`,
      session,
    ).then(data => {
      setMetrics(Array.isArray(data) ? data : [])
      setLoading(false)
    }).catch(() => setLoading(false))
  }, [userId])

  if (loading) return <SkeletonLoader />

  return (
    <div style={{ padding: '24px 20px', maxWidth: 480, margin: '0 auto', width: '100%' }}>
      {metrics.length === 0 ? (
        <div style={{ backgroundColor: '#1A1A2E', border: '1px solid #2A2A3E', borderRadius: 14, padding: '32px', textAlign: 'center' }}>
          <TrendingUp size={40} color="#8B8FA8" style={{ margin: '0 auto 12px', display: 'block' }} />
          <div style={{ fontSize: 16, fontWeight: 700, color: 'white', marginBottom: 8 }}>No platform data yet</div>
          <div style={{ fontSize: 13, color: '#8B8FA8' }}>Connect YouTube or Twitch to see your scores</div>
          <a href="/profile" style={{ display: 'inline-block', marginTop: 16, backgroundColor: '#6C63FF', borderRadius: 10, padding: '10px 24px', color: 'white', fontWeight: 700, fontSize: 14, textDecoration: 'none' }}>
            Connect Platforms
          </a>
        </div>
      ) : metrics.map((m, i) => {
        const isYT = m.platform === 'youtube'
        const pc = isYT ? '#FF4444' : '#9146FF'
        const platformLabel = isYT ? 'YouTube' : 'Twitch'
        return (
          <div key={i} style={{ backgroundColor: '#1A1A2E', border: '1px solid #2A2A3E', borderRadius: 14, padding: 18, marginBottom: 14 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 16 }}>
              <span style={{ fontSize: 12, fontWeight: 600, color: pc, backgroundColor: pc + '1F', border: `1px solid ${pc}59`, borderRadius: 6, padding: '3px 8px' }}>{platformLabel}</span>
              {m.is_live && <span style={{ fontSize: 10, fontWeight: 700, color: '#FF4757', backgroundColor: 'rgba(255,71,87,0.12)', border: '1px solid rgba(255,71,87,0.4)', borderRadius: 999, padding: '2px 7px' }}>🔴 LIVE</span>}
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 12 }}>
              <ScoreTile label="Heat Score" value={m.heat_score?.toFixed(1) ?? '—'} highlight />
              <ScoreTile label="Raw Score" value={m.display_score?.toFixed(1) ?? '—'} />
              <ScoreTile label="Followers" value={formatNum(m.follower_count)} />
              {m.is_live && <ScoreTile label="Viewers" value={formatNum(m.live_viewer_count)} />}
            </div>

            <div style={{ fontSize: 11, color: '#8B8FA8', marginTop: 12, textAlign: 'right' }}>
              Updated {m.updated_at ? new Date(m.updated_at).toLocaleTimeString() : '—'}
            </div>
          </div>
        )
      })}

      <OpenInApp path="/dashboard" />
    </div>
  )
}

function ScoreTile({ label, value, highlight }) {
  return (
    <div style={{ backgroundColor: '#16213E', borderRadius: 10, padding: '10px 12px' }}>
      <div style={{ fontSize: 10, color: '#8B8FA8', marginBottom: 4, fontWeight: 600, letterSpacing: '0.04em', textTransform: 'uppercase' }}>{label}</div>
      <div style={{ fontSize: 18, fontWeight: 800, color: highlight ? '#6C63FF' : 'white' }}>{value}</div>
    </div>
  )
}

function SkeletonLoader() {
  return <div style={{ padding: 24 }}>{[1,2].map(i => <div key={i} style={{ height: 160, backgroundColor: '#1A1A2E', borderRadius: 14, marginBottom: 14, opacity: 0.6 }} />)}</div>
}

function OpenInApp({ path }) {
  return (
    <a href={path} style={{ display: 'block', textAlign: 'center', backgroundColor: '#6C63FF', borderRadius: 12, padding: '14px', color: 'white', fontWeight: 700, fontSize: 15, textDecoration: 'none', marginTop: 4, transition: 'background-color 0.15s' }}
      onMouseEnter={e => e.currentTarget.style.backgroundColor = '#7B73FF'}
      onMouseLeave={e => e.currentTarget.style.backgroundColor = '#6C63FF'}
    >
      Open Full Dashboard in App →
    </a>
  )
}

function formatNum(n) {
  if (!n) return '—'
  if (n >= 1_000_000) return `${(n/1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n/1_000).toFixed(1)}K`
  return String(n)
}
