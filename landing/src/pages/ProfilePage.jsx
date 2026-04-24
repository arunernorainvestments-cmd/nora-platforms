import { useState, useEffect } from 'react'
import { User, Link, Award } from 'lucide-react'
import { PageShell } from '../components/PageShell'
import { sbFetchAuth } from '../supabase'

export default function ProfilePage() {
  return (
    <PageShell title="Profile" requireAuth>
      {session => <ProfileContent session={session} />}
    </PageShell>
  )
}

function ProfileContent({ session }) {
  const [profile, setProfile] = useState(null)
  const [connections, setConnections] = useState([])
  const [loading, setLoading] = useState(true)
  const userId = session.user.id

  useEffect(() => {
    Promise.all([
      sbFetchAuth(`profiles?id=eq.${userId}&select=username,display_name,bio,category_1,category_2,is_market_maker,referral_code`, session),
      sbFetchAuth(`platform_connections?user_id=eq.${userId}&select=platform,platform_username,is_active`, session),
    ]).then(([prof, conns]) => {
      setProfile(Array.isArray(prof) ? prof[0] : prof)
      setConnections(Array.isArray(conns) ? conns.filter(c => c.is_active) : [])
      setLoading(false)
    }).catch(() => setLoading(false))
  }, [userId])

  if (loading) return <LoadingState />

  const avatar = (profile?.display_name || profile?.username || '?')[0]?.toUpperCase()

  return (
    <div style={{ padding: '24px 20px', maxWidth: 480, margin: '0 auto', width: '100%' }}>
      {/* Avatar + name */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 16, marginBottom: 24 }}>
        <div style={{ width: 72, height: 72, borderRadius: '50%', background: 'linear-gradient(135deg, #6C63FF, #03DAC6)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 28, fontWeight: 800, color: 'white', flexShrink: 0 }}>
          {avatar}
        </div>
        <div>
          <div style={{ fontSize: 22, fontWeight: 800, color: 'white' }}>{profile?.display_name || profile?.username || 'User'}</div>
          <div style={{ fontSize: 14, color: '#8B8FA8' }}>@{profile?.username}</div>
          {profile?.is_market_maker && (
            <span style={{ fontSize: 10, fontWeight: 700, color: '#03DAC6', backgroundColor: 'rgba(3,218,198,0.12)', border: '1px solid rgba(3,218,198,0.4)', borderRadius: 999, padding: '2px 8px', display: 'inline-block', marginTop: 4 }}>
              Market Maker
            </span>
          )}
        </div>
      </div>

      {/* Bio */}
      {profile?.bio && (
        <div style={{ backgroundColor: '#1A1A2E', border: '1px solid #2A2A3E', borderRadius: 12, padding: 16, marginBottom: 16 }}>
          <p style={{ margin: 0, fontSize: 14, color: '#C8CAD8', lineHeight: 1.6 }}>{profile.bio}</p>
        </div>
      )}

      {/* Categories */}
      {(profile?.category_1 || profile?.category_2) && (
        <div style={{ display: 'flex', gap: 8, marginBottom: 16, flexWrap: 'wrap' }}>
          {[profile.category_1, profile.category_2].filter(Boolean).map(cat => (
            <span key={cat} style={{ fontSize: 12, color: '#8B8FA8', backgroundColor: '#1A1A2E', border: '1px solid #2A2A3E', borderRadius: 999, padding: '4px 12px' }}>{cat}</span>
          ))}
        </div>
      )}

      {/* Connected platforms */}
      <Section icon={<Link size={15} />} label="Connected Platforms">
        {connections.length === 0 ? (
          <Empty text="No platforms connected yet" />
        ) : connections.map(c => (
          <Row key={c.platform} left={
            <span style={{ fontSize: 13, fontWeight: 600, color: c.platform === 'youtube' ? '#FF4444' : '#9146FF', backgroundColor: c.platform === 'youtube' ? '#FF44441F' : '#9146FF1F', border: `1px solid ${c.platform === 'youtube' ? '#FF444459' : '#9146FF59'}`, borderRadius: 6, padding: '3px 8px' }}>
              {c.platform === 'youtube' ? 'YouTube' : 'Twitch'}
            </span>
          } right={<span style={{ color: 'white', fontWeight: 600 }}>@{c.platform_username}</span>} />
        ))}
      </Section>

      {/* Referral */}
      {profile?.referral_code && (
        <Section icon={<Award size={15} />} label="Referral Code">
          <Row left={<span style={{ color: '#8B8FA8' }}>Your code</span>} right={
            <span style={{ fontFamily: 'monospace', color: '#6C63FF', fontWeight: 700, fontSize: 15 }}>{profile.referral_code}</span>
          } />
        </Section>
      )}

      <OpenInApp path="/profile" />
    </div>
  )
}

function Section({ icon, label, children }) {
  return (
    <div style={{ backgroundColor: '#1A1A2E', border: '1px solid #2A2A3E', borderRadius: 14, padding: 16, marginBottom: 16 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 12, color: '#8B8FA8' }}>
        {icon}
        <span style={{ fontSize: 11, fontWeight: 700, letterSpacing: '0.08em', textTransform: 'uppercase' }}>{label}</span>
      </div>
      {children}
    </div>
  )
}

function Row({ left, right }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0' }}>
      <span style={{ fontSize: 13, color: '#8B8FA8' }}>{left}</span>
      <span style={{ fontSize: 13 }}>{right}</span>
    </div>
  )
}

function Empty({ text }) {
  return <p style={{ margin: 0, fontSize: 13, color: '#8B8FA8', textAlign: 'center', padding: '8px 0' }}>{text}</p>
}

function LoadingState() {
  return (
    <div style={{ padding: 24 }}>
      {[80, 200, 140, 160].map((w, i) => (
        <div key={i} style={{ height: 16, width: w, backgroundColor: '#1A1A2E', borderRadius: 8, marginBottom: 14, opacity: 0.6 }} />
      ))}
    </div>
  )
}

function OpenInApp({ path }) {
  return (
    <a href={path} style={{ display: 'block', textAlign: 'center', backgroundColor: '#6C63FF', borderRadius: 12, padding: '14px', color: 'white', fontWeight: 700, fontSize: 15, textDecoration: 'none', marginTop: 8, transition: 'background-color 0.15s' }}
      onMouseEnter={e => e.currentTarget.style.backgroundColor = '#7B73FF'}
      onMouseLeave={e => e.currentTarget.style.backgroundColor = '#6C63FF'}
    >
      Open Full Profile in App →
    </a>
  )
}
