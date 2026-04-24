import { useState, useEffect } from 'react'
import { Flame, Eye, Radio } from 'lucide-react'
import { PageShell } from '../components/PageShell'
import { sbFetch } from '../supabase'

export default function ExplorePage() {
  return (
    <PageShell title="Explore — Who's Hot">
      {() => <ExploreContent />}
    </PageShell>
  )
}

function ExploreContent() {
  const [live, setLive] = useState([])
  const [rising, setRising] = useState([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    Promise.all([
      sbFetch('platform_metrics?is_live=eq.true&select=user_id,platform,heat_score,live_viewer_count,stream_title,stream_category,platform_connections(platform_username)&order=heat_score.desc&limit=15'),
      sbFetch('profiles?is_creator=eq.true&select=id,display_name,username,spotlight_scores(tier),platform_metrics(heat_score)&order=created_at.desc&limit=20'),
    ]).then(([liveData, risingData]) => {
      setLive(Array.isArray(liveData) ? liveData : [])
      setRising(Array.isArray(risingData) ? risingData.map(r => {
        const m = Array.isArray(r.platform_metrics) ? r.platform_metrics : r.platform_metrics ? [r.platform_metrics] : []
        const sp = Array.isArray(r.spotlight_scores) ? r.spotlight_scores[0] : r.spotlight_scores
        return { id: r.id, label: r.display_name || r.username || 'Creator', tier: sp?.tier ?? null, heatScore: m.length ? Math.max(...m.map(x => x.heat_score ?? 0)) : 0 }
      }) : [])
      setLoading(false)
    }).catch(() => setLoading(false))
  }, [])

  if (loading) return <SkeletonLoader />

  return (
    <div style={{ padding: '20px', maxWidth: 600, margin: '0 auto', width: '100%' }}>

      {/* Who's Live */}
      <SectionHeader icon={<Radio size={15} color="#FF4757" />} title="Who's Live" subtitle="Streaming right now" />
      {live.length === 0 ? (
        <Empty text="No creators are live right now" />
      ) : live.map((m, i) => {
        const isYT = m.platform === 'youtube'
        const conn = Array.isArray(m.platform_connections) ? m.platform_connections[0] : m.platform_connections
        const username = conn?.platform_username ?? 'Unknown'
        const pc = isYT ? '#FF4444' : '#9146FF'
        const viewers = formatViewers(m.live_viewer_count ?? 0)
        return (
          <div key={i} style={{ backgroundColor: '#1A1A2E', border: '1px solid #2A2A3E', borderRadius: 14, padding: 16, marginBottom: 10 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: m.stream_title ? 8 : 0 }}>
              <span style={{ fontSize: 11, fontWeight: 600, color: pc, backgroundColor: pc + '1F', border: `1px solid ${pc}59`, borderRadius: 6, padding: '3px 7px', flexShrink: 0 }}>
                {isYT ? 'YT' : 'Twitch'}
              </span>
              <span style={{ flex: 1, fontSize: 15, fontWeight: 700, color: 'white', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>@{username}</span>
              <span style={{ display: 'flex', alignItems: 'center', gap: 4, fontSize: 12, fontWeight: 700, color: '#6C63FF', backgroundColor: '#6C63FF1F', border: '1px solid #6C63FF66', borderRadius: 12, padding: '4px 9px', flexShrink: 0 }}>
                🔥 {m.heat_score?.toFixed(1) ?? '—'}
              </span>
            </div>
            {m.stream_title && <p style={{ margin: '0 0 4px', fontSize: 13, color: '#C8CAD8', overflow: 'hidden', display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical' }}>{m.stream_title}</p>}
            {m.stream_category && <p style={{ margin: '0 0 8px', fontSize: 12, color: '#8B8FA8' }}>{m.stream_category}</p>}
            <div style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
              <Eye size={13} color="#FF4757" />
              <span style={{ fontSize: 13, fontWeight: 600, color: '#FF4757' }}>{viewers}</span>
              <span style={{ fontSize: 12, color: '#8B8FA8' }}>watching</span>
            </div>
          </div>
        )
      })}

      {/* Rising Creators */}
      <SectionHeader icon={<Flame size={15} color="#FFD700" />} title="Rising Creators" subtitle="Gaining traction" />
      <div style={{ display: 'flex', gap: 10, overflowX: 'auto', paddingBottom: 4 }}>
        {rising.length === 0 ? <Empty text="No creators yet" /> : rising.map(c => {
          const color = avatarColor(c.label)
          return (
            <div key={c.id} style={{ width: 100, flexShrink: 0, backgroundColor: '#1A1A2E', border: '1px solid #2A2A3E', borderRadius: 14, padding: 12, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6 }}>
              <div style={{ width: 44, height: 44, borderRadius: '50%', backgroundColor: color + '26', border: `1.5px solid ${color}66`, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 18, fontWeight: 700, color }}>
                {c.label[0].toUpperCase()}
              </div>
              <div style={{ fontSize: 11, fontWeight: 600, color: 'white', textAlign: 'center', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', width: '100%' }}>{c.label}</div>
              {c.heatScore > 0 && <div style={{ fontSize: 10, color: '#8B8FA8' }}>🔥 {c.heatScore.toFixed(1)}</div>}
            </div>
          )
        })}
      </div>
    </div>
  )
}

function SectionHeader({ icon, title, subtitle }) {
  return (
    <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, margin: '20px 0 12px' }}>
      {icon}
      <span style={{ fontSize: 17, fontWeight: 700, color: 'white' }}>{title}</span>
      <span style={{ fontSize: 12, color: '#8B8FA8' }}>{subtitle}</span>
    </div>
  )
}

function Empty({ text }) {
  return <div style={{ backgroundColor: '#1A1A2E', border: '1px solid #2A2A3E', borderRadius: 12, padding: '24px', textAlign: 'center', color: '#8B8FA8', fontSize: 14, marginBottom: 10 }}>{text}</div>
}

function SkeletonLoader() {
  return <div style={{ padding: 20 }}>{[1,2,3].map(i => <div key={i} style={{ height: 80, backgroundColor: '#1A1A2E', borderRadius: 14, marginBottom: 10, opacity: 0.6 }} />)}</div>
}

function formatViewers(n) {
  if (n >= 1_000_000) return `${(n/1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n/1_000).toFixed(1)}K`
  return String(n)
}

const PALETTE = ['#6C63FF','#00C896','#FF6B35','#EE1D52','#9146FF','#FFD700','#00BCD4']
function avatarColor(label) {
  const code = [...label].reduce((s, c) => s + c.charCodeAt(0), 0)
  return PALETTE[code % PALETTE.length]
}
