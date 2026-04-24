import { useState, useEffect, useRef, useCallback } from 'react'
import { Link } from 'react-router-dom'
import {
  Menu, Search, TrendingUp, ChevronLeft, ChevronRight, X,
  LayoutDashboard, User, Receipt, Wallet, Trophy, Flame,
  Settings, HelpCircle, Crown, LogIn, Zap, Radio, Eye,
} from 'lucide-react'
import { sbFetch } from './supabase'

function useRisingCreators() {
  const [creators, setCreators] = useState([])
  const [liveIds, setLiveIds] = useState(new Set())
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let cancelled = false
    Promise.all([
      sbFetch('profiles?is_creator=eq.true&select=id,display_name,username,spotlight_scores(tier),platform_metrics(heat_score)&order=created_at.desc&limit=20'),
      sbFetch('platform_metrics?is_live=eq.true&select=user_id'),
    ]).then(([rows, liveRows]) => {
      if (cancelled) return
      const ids = new Set((liveRows || []).map(r => r.user_id))
      const parsed = (rows || []).map(r => {
        const metrics = Array.isArray(r.platform_metrics) ? r.platform_metrics : r.platform_metrics ? [r.platform_metrics] : []
        const heatScore = metrics.length ? Math.max(...metrics.map(m => m.heat_score ?? 0)) : 0
        const sp = Array.isArray(r.spotlight_scores) ? r.spotlight_scores[0] : r.spotlight_scores
        return {
          id: r.id,
          label: r.display_name || r.username || 'Anonymous',
          tier: sp?.tier ?? null,
          heatScore,
        }
      })
      setLiveIds(ids)
      setCreators(parsed)
      setLoading(false)
    }).catch(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [])

  return { creators, liveIds, loading }
}

function useLiveFeed() {
  const [metrics, setMetrics] = useState([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let cancelled = false
    sbFetch('platform_metrics?is_live=eq.true&select=user_id,platform,display_score,heat_score,live_viewer_count,stream_title,stream_category,platform_connections(platform_username)&order=display_score.desc&limit=20')
      .then(rows => {
        if (cancelled) return
        const parsed = (rows || []).map(r => {
          const conn = Array.isArray(r.platform_connections) ? r.platform_connections[0] : r.platform_connections
          return {
            userId: r.user_id,
            platform: r.platform,
            heatScore: r.heat_score ?? 0,
            viewers: r.live_viewer_count ?? 0,
            streamTitle: r.stream_title ?? null,
            streamCategory: r.stream_category ?? null,
            username: conn?.platform_username ?? null,
          }
        })
        setMetrics(parsed)
        setLoading(false)
      })
      .catch(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [])

  return { metrics, loading }
}

// ─── Mock data ────────────────────────────────────────────────────────────────

const CREATORS = [
  {
    rank: 1,
    username: 'JordanKicks',
    category: 'Athlete',
    scoreDelta: '+2,340',
    platforms: [['YouTube', '+50'], ['TikTok', '+24'], ['Twitch', '+7']],
    gradientFrom: 'hsl(258 70% 28%)',
    gradientTo: 'hsl(258 50% 10%)',
    accentColor: '#9B8FFF',
  },
  {
    rank: 2,
    username: 'CreatorKing',
    category: 'Influencer',
    scoreDelta: '+1,890',
    platforms: [['YouTube', '+32'], ['Instagram', '+18'], ['TikTok', '+11']],
    gradientFrom: 'hsl(174 55% 22%)',
    gradientTo: 'hsl(174 40% 8%)',
    accentColor: '#03DAC6',
  },
  {
    rank: 3,
    username: 'BeatMaster',
    category: 'Artist',
    scoreDelta: '+1,650',
    platforms: [['YouTube', '+45'], ['Spotify', '+12'], ['TikTok', '+8']],
    gradientFrom: 'hsl(340 60% 28%)',
    gradientTo: 'hsl(340 45% 8%)',
    accentColor: '#FF6B81',
  },
  {
    rank: 4,
    username: 'DrNovak',
    category: 'Scientist',
    scoreDelta: '+1,200',
    platforms: [['YouTube', '+28'], ['X', '+15'], ['LinkedIn', '+9']],
    gradientFrom: 'hsl(210 60% 25%)',
    gradientTo: 'hsl(210 45% 8%)',
    accentColor: '#60A5FA',
  },
  {
    rank: 5,
    username: 'ExecElena',
    category: 'Professional',
    scoreDelta: '+980',
    platforms: [['LinkedIn', '+30'], ['YouTube', '+15'], ['X', '+6']],
    gradientFrom: 'hsl(30 65% 25%)',
    gradientTo: 'hsl(30 45% 8%)',
    accentColor: '#FBB040',
  },
]

const NEWS = [
  { text: 'JordanKicks breaks 1M followers', time: '2m ago' },
  { text: 'New weekly score record set by CreatorKing', time: '14m ago' },
  { text: 'BeatMaster drops surprise album — fans react', time: '1h ago' },
]

const TABS = [
  { label: 'Trending' },
  { label: 'Athletes' },
  { label: 'Influencers' },
  { label: 'Artists' },
  { label: 'Scientists' },
  { label: 'Professionals' },
  { label: 'Explore All', href: '/markets' },
]

const ORDINALS = ['1st', '2nd', '3rd', '4th', '5th']

// ─── Sub-components ───────────────────────────────────────────────────────────

function AvatarCircle({ name, size = 36, accent }) {
  return (
    <div style={{
      width: size, height: size, borderRadius: '50%', flexShrink: 0,
      background: `linear-gradient(135deg, ${accent ?? '#6C63FF'}, #03DAC6)`,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      fontSize: size * 0.4, fontWeight: 800, color: 'white', userSelect: 'none',
    }}>
      {name[0].toUpperCase()}
    </div>
  )
}

function RankCard({ creator, isActive, onClick }) {
  return (
    <button
      onClick={onClick}
      style={{
        display: 'flex', alignItems: 'center', gap: 10,
        borderRadius: 12, padding: '10px 12px',
        backgroundColor: isActive ? '#16213E' : '#1A1A2E',
        border: `1px solid ${isActive ? '#6C63FF' : '#2A2A3E'}`,
        cursor: 'pointer', textAlign: 'left',
        transition: 'background-color 0.2s, border-color 0.2s',
        boxShadow: isActive ? '0 0 0 1px rgba(108,99,255,0.25)' : 'none',
      }}
    >
      <span style={{ fontSize: 11, fontWeight: 700, color: '#8B8FA8', minWidth: 26 }}>
        {ORDINALS[creator.rank - 1]}
      </span>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 13, fontWeight: 600, color: 'white', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {creator.username}
        </div>
        <div style={{ fontSize: 11, color: '#8B8FA8', marginTop: 1 }}>{creator.category}</div>
      </div>
      <AvatarCircle name={creator.username} size={34} accent={creator.accentColor} />
    </button>
  )
}

function NewsPanel() {
  return (
    <div style={{
      backgroundColor: '#1A1A2E', border: '1px solid #2A2A3E',
      borderRadius: 12, padding: '14px 16px',
    }}>
      <a
        href="/explore"
        style={{
          display: 'inline-flex', alignItems: 'center', gap: 5,
          backgroundColor: '#FF4757', borderRadius: 999, padding: '4px 12px',
          fontSize: 11, fontWeight: 700, color: 'white', marginBottom: 14,
          letterSpacing: '0.02em', textDecoration: 'none',
          transition: 'background-color 0.15s, box-shadow 0.15s',
          cursor: 'pointer',
        }}
        onMouseEnter={e => { e.currentTarget.style.backgroundColor = '#FF6070'; e.currentTarget.style.boxShadow = '0 0 12px rgba(255,71,87,0.45)' }}
        onMouseLeave={e => { e.currentTarget.style.backgroundColor = '#FF4757'; e.currentTarget.style.boxShadow = 'none' }}
        title="See Who's Hot Right Now"
      >
        🔥 Breaking News
      </a>
      {NEWS.map((item, i) => (
        <div
          key={i}
          style={{
            paddingBottom: i < NEWS.length - 1 ? 10 : 0,
            marginBottom: i < NEWS.length - 1 ? 10 : 0,
            borderBottom: i < NEWS.length - 1 ? '1px solid #2A2A3E' : 'none',
          }}
        >
          <p style={{ margin: 0, fontSize: 12, lineHeight: 1.55, color: 'white' }}>{item.text}</p>
          <p style={{ margin: '3px 0 0', fontSize: 11, color: '#8B8FA8' }}>{item.time}</p>
        </div>
      ))}
    </div>
  )
}

const TOKEN_PACKAGES = [
  { id: 'starter', label: 'Starter',  tokens: 120,  price: '$0.99',  badge: null },
  { id: 'popular', label: 'Popular',  tokens: 650,  price: '$4.99',  badge: 'Most Popular' },
  { id: 'pro',     label: 'Pro',      tokens: 1650, price: '$9.99',  badge: 'Best Value' },
  { id: 'elite',   label: 'Elite',    tokens: 3500, price: '$19.99', badge: null },
]

function TokensModal({ onClose }) {
  const [view, setView] = useState('choice') // 'choice' | 'purchase'
  const [earnHovered, setEarnHovered] = useState(false)
  const [hoveredPkg, setHoveredPkg] = useState(null)

  const closeBtn = (
    <button
      onClick={view === 'purchase' ? () => setView('choice') : onClose}
      style={{
        position: 'absolute', top: 14, right: 14,
        background: 'rgba(42,42,62,0.8)', border: 'none', cursor: 'pointer',
        color: '#8B8FA8', display: 'flex', borderRadius: 8,
        padding: 7, transition: 'background 0.15s, color 0.15s',
      }}
      onMouseEnter={e => { e.currentTarget.style.background = 'rgba(108,99,255,0.2)'; e.currentTarget.style.color = 'white' }}
      onMouseLeave={e => { e.currentTarget.style.background = 'rgba(42,42,62,0.8)'; e.currentTarget.style.color = '#8B8FA8' }}
    >
      <X size={16} />
    </button>
  )

  return (
    <>
      {/* Backdrop */}
      <div onClick={onClose} style={{ position: 'fixed', inset: 0, zIndex: 100, backgroundColor: 'rgba(0,0,0,0.72)', backdropFilter: 'blur(6px)' }} />

      {/* Modal card */}
      <div style={{
        position: 'fixed', zIndex: 101,
        top: '50%', left: '50%', transform: 'translate(-50%, -50%)',
        width: 'min(440px, calc(100vw - 48px))',
        backgroundColor: '#1A1A2E', border: '1px solid #2A2A3E',
        borderRadius: 20, padding: '32px 28px 28px',
        boxShadow: '0 24px 80px rgba(0,0,0,0.7)',
        animation: 'fadeIn 0.18s ease forwards',
        maxHeight: 'calc(100vh - 48px)', overflowY: 'auto',
      }}>
        {closeBtn}

        {view === 'choice' ? (
          <>
            <div style={{ width: 52, height: 52, borderRadius: '50%', margin: '0 auto 20px', background: 'linear-gradient(135deg, #6C63FF, #03DAC6)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 24 }}>🪙</div>
            <h2 style={{ margin: '0 0 8px', textAlign: 'center', fontSize: 20, fontWeight: 800, color: 'white', letterSpacing: '-0.3px' }}>
              How do you want more tokens?
            </h2>
            <p style={{ margin: '0 0 24px', textAlign: 'center', fontSize: 13, color: '#8B8FA8', lineHeight: 1.5 }}>
              Tokens power promotions, boosts, and bets on the platform.
            </p>

            <div style={{ display: 'flex', gap: 12, marginBottom: 20 }}>
              {/* Purchase — opens package view */}
              <button
                onClick={() => setView('purchase')}
                style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6, backgroundColor: '#6C63FF', border: 'none', borderRadius: 14, padding: '18px 12px', cursor: 'pointer', transition: 'background-color 0.15s, box-shadow 0.15s' }}
                onMouseEnter={e => { e.currentTarget.style.backgroundColor = '#7B73FF'; e.currentTarget.style.boxShadow = '0 0 20px rgba(108,99,255,0.45)' }}
                onMouseLeave={e => { e.currentTarget.style.backgroundColor = '#6C63FF'; e.currentTarget.style.boxShadow = 'none' }}
              >
                <span style={{ fontSize: 24 }}>💳</span>
                <span style={{ fontSize: 15, fontWeight: 700, color: 'white' }}>Purchase</span>
                <span style={{ fontSize: 11, color: 'rgba(255,255,255,0.7)', textAlign: 'center' }}>Buy token packs instantly</span>
              </button>

              {/* Earn */}
              <a href="/challenges" onMouseEnter={() => setEarnHovered(true)} onMouseLeave={() => setEarnHovered(false)}
                style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6, textDecoration: 'none', backgroundColor: earnHovered ? 'rgba(3,218,198,0.18)' : 'rgba(3,218,198,0.10)', border: `1px solid ${earnHovered ? '#03DAC6' : 'rgba(3,218,198,0.4)'}`, borderRadius: 14, padding: '18px 12px', cursor: 'pointer', transition: 'background-color 0.15s, border-color 0.15s, box-shadow 0.15s', boxShadow: earnHovered ? '0 0 20px rgba(3,218,198,0.2)' : 'none' }}
              >
                <span style={{ fontSize: 24 }}>🏆</span>
                <span style={{ fontSize: 15, fontWeight: 700, color: '#03DAC6' }}>Earn</span>
                <span style={{ fontSize: 11, color: '#8B8FA8', textAlign: 'center' }}>Complete challenges &amp; win bets</span>
              </a>
            </div>

            {/* Equality note */}
            <div style={{ backgroundColor: 'rgba(108,99,255,0.07)', border: '1px solid rgba(108,99,255,0.2)', borderRadius: 12, padding: '12px 14px', display: 'flex', gap: 10, alignItems: 'flex-start' }}>
              <span style={{ fontSize: 16, flexShrink: 0, marginTop: 1 }}>🤝</span>
              <p style={{ margin: 0, fontSize: 12, color: '#A8AABC', lineHeight: 1.6 }}>
                We believe everyone should have access to the same promotion power.
                If you cannot afford tokens, we ensure you will have the same opportunity as those with more affordability.
              </p>
            </div>
          </>
        ) : (
          <>
            <h2 style={{ margin: '0 0 4px', fontSize: 20, fontWeight: 800, color: 'white', letterSpacing: '-0.3px' }}>Buy Tokens</h2>
            <p style={{ margin: '0 0 20px', fontSize: 13, color: '#8B8FA8' }}>Tokens fuel promotions, bets, and power-ups.</p>

            {TOKEN_PACKAGES.map(pkg => {
              const isPopular = pkg.badge === 'Most Popular'
              const hovered = hoveredPkg === pkg.id
              return (
                <a key={pkg.id} href="/wallet"
                  onMouseEnter={() => setHoveredPkg(pkg.id)}
                  onMouseLeave={() => setHoveredPkg(null)}
                  style={{ display: 'flex', alignItems: 'center', gap: 14, textDecoration: 'none', backgroundColor: '#16213E', border: `${isPopular ? 1.5 : 1}px solid ${isPopular ? '#6C63FF' : hovered ? '#3A3A5E' : '#2A2A3E'}`, borderRadius: 14, padding: '14px 16px', marginBottom: 10, transition: 'border-color 0.15s, box-shadow 0.15s', boxShadow: hovered ? '0 4px 16px rgba(108,99,255,0.15)' : 'none' }}
                >
                  <div style={{ width: 44, height: 44, borderRadius: 10, flexShrink: 0, backgroundColor: '#1A1A2E', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 20 }}>🪙</div>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 2 }}>
                      <span style={{ fontSize: 15, fontWeight: 700, color: 'white' }}>{pkg.label}</span>
                      {pkg.badge && (
                        <span style={{ fontSize: 9, fontWeight: 700, letterSpacing: '0.05em', color: isPopular ? '#9B8FFF' : '#03DAC6', backgroundColor: isPopular ? 'rgba(108,99,255,0.15)' : 'rgba(3,218,198,0.12)', border: `1px solid ${isPopular ? 'rgba(108,99,255,0.4)' : 'rgba(3,218,198,0.4)'}`, borderRadius: 999, padding: '2px 7px', textTransform: 'uppercase' }}>
                          {pkg.badge}
                        </span>
                      )}
                    </div>
                    <div style={{ fontSize: 12, color: '#8B8FA8' }}>{pkg.tokens.toLocaleString()} tokens</div>
                  </div>
                  <div style={{ fontSize: 16, fontWeight: 700, color: isPopular ? '#9B8FFF' : 'white', flexShrink: 0 }}>{pkg.price}</div>
                </a>
              )
            })}

            <p style={{ margin: '12px 0 0', fontSize: 11, color: '#8B8FA8', textAlign: 'center', lineHeight: 1.5 }}>
              Sign in to complete your purchase in the app.
            </p>
          </>
        )}
      </div>
    </>
  )
}

function GetTokensButton() {
  const [hovered, setHovered] = useState(false)
  const [modalOpen, setModalOpen] = useState(false)
  return (
    <>
      {modalOpen && <TokensModal onClose={() => setModalOpen(false)} />}
      <button
        onClick={() => setModalOpen(true)}
        onMouseEnter={() => setHovered(true)}
        onMouseLeave={() => setHovered(false)}
        style={{
          backgroundColor: hovered ? '#16213E' : '#1A1A2E',
          border: '1px solid #6C63FF',
          borderRadius: 12, color: 'white',
          fontSize: 22, fontWeight: 800, cursor: 'pointer',
          padding: '28px 0', width: '100%',
          lineHeight: 1.35, transition: 'background-color 0.2s',
          boxShadow: hovered ? '0 0 24px rgba(108,99,255,0.3)' : 'none',
        }}
      >
        Get<br />Tokens
      </button>
    </>
  )
}

// ─── Spotlight card ───────────────────────────────────────────────────────────

function SpotlightCard({ creator, onPrev, onNext, currentSlide, onDotClick }) {
  return (
    <div style={{
      flex: 1, position: 'relative', borderRadius: 18, overflow: 'hidden',
      minHeight: 380, border: '1px solid #2A2A3E',
    }}>
      {/* Background gradient — transitions on creator change */}
      <div
        key={`bg-${creator.rank}`}
        style={{
          position: 'absolute', inset: 0,
          background: `radial-gradient(ellipse at 50% 0%, ${creator.gradientFrom} 0%, ${creator.gradientTo} 65%, #0A0A0F 100%)`,
          animation: 'fadeIn 0.5s ease forwards',
        }}
      />

      {/* Bottom fade overlay */}
      <div style={{
        position: 'absolute', inset: 0,
        background: 'linear-gradient(to top, rgba(5,5,15,0.92) 0%, rgba(5,5,15,0.4) 45%, transparent 100%)',
      }} />

      {/* Top-left subtle vignette */}
      <div style={{
        position: 'absolute', inset: 0,
        background: 'radial-gradient(ellipse at 0% 0%, rgba(0,0,0,0.35) 0%, transparent 60%)',
        pointerEvents: 'none',
      }} />

      {/* Score badge */}
      <div style={{
        position: 'absolute', top: 16, right: 16,
        display: 'flex', alignItems: 'center', gap: 6,
        backgroundColor: 'rgba(0,200,150,0.12)',
        border: '1px solid #00C896',
        borderRadius: 999, padding: '6px 13px',
        fontSize: 13, fontWeight: 700, color: '#00C896',
        backdropFilter: 'blur(6px)',
      }}>
        <TrendingUp size={14} />
        {creator.scoreDelta} pts
      </div>

      {/* Left chevron */}
      <ChevronButton direction="left" onClick={onPrev} />

      {/* Right chevron */}
      <ChevronButton direction="right" onClick={onNext} />

      {/* Bottom content — fades in with each new creator */}
      <div
        key={`content-${creator.rank}`}
        style={{ position: 'absolute', inset: 0, animation: 'slideUp 0.4s ease forwards' }}
      >
        {/* Follower count pill */}
        <div style={{
          position: 'absolute', bottom: 48, left: 18,
          backgroundColor: 'rgba(10,10,20,0.72)',
          backdropFilter: 'blur(10px)',
          borderRadius: 10, padding: '9px 13px',
          fontSize: 12, border: '1px solid rgba(42,42,62,0.8)',
        }}>
          <div style={{ color: '#8B8FA8', fontWeight: 600, marginBottom: 5, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em' }}>
            Follower Count
          </div>
          {creator.platforms.map(([platform, delta]) => (
            <div key={platform} style={{ display: 'flex', gap: 8, marginBottom: 2 }}>
              <span style={{ color: '#8B8FA8', minWidth: 60 }}>{platform}:</span>
              <span style={{ color: '#00C896', fontWeight: 600 }}>{delta}</span>
            </div>
          ))}
        </div>

        {/* Username + category */}
        <div style={{ position: 'absolute', bottom: 48, right: 20, textAlign: 'right' }}>
          <div style={{ fontSize: 22, fontWeight: 800, letterSpacing: '-0.3px', textShadow: '0 2px 12px rgba(0,0,0,0.6)' }}>
            {creator.username}
          </div>
          <div style={{ fontSize: 13, color: '#8B8FA8', marginTop: 3 }}>{creator.category}</div>
        </div>
      </div>

      {/* Pagination dots */}
      <div style={{
        position: 'absolute', bottom: 14, left: '50%', transform: 'translateX(-50%)',
        display: 'flex', gap: 6, alignItems: 'center',
      }}>
        {CREATORS.map((_, i) => (
          <button
            key={i}
            onClick={() => onDotClick(i)}
            style={{
              height: 7,
              width: i === currentSlide ? 22 : 7,
              borderRadius: 999, border: 'none', cursor: 'pointer', padding: 0,
              backgroundColor: i === currentSlide ? '#6C63FF' : 'rgba(255,255,255,0.28)',
              transition: 'all 0.3s ease',
            }}
          />
        ))}
      </div>
    </div>
  )
}

function ChevronButton({ direction, onClick }) {
  const [hovered, setHovered] = useState(false)
  const isLeft = direction === 'left'
  return (
    <button
      onClick={onClick}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      style={{
        position: 'absolute',
        [isLeft ? 'left' : 'right']: 14,
        top: '50%', transform: 'translateY(-50%)',
        width: 40, height: 40, borderRadius: '50%', border: 'none',
        cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center',
        backgroundColor: hovered ? 'rgba(255,255,255,0.25)' : 'rgba(255,255,255,0.13)',
        backdropFilter: 'blur(8px)',
        transition: 'background-color 0.2s',
        zIndex: 10,
      }}
    >
      {isLeft ? <ChevronLeft size={22} color="white" /> : <ChevronRight size={22} color="white" />}
    </button>
  )
}

// ─── Hamburger side drawer ────────────────────────────────────────────────────

const NAV_ITEMS = [
  {
    icon: LayoutDashboard,
    label: 'Dashboard',
    to: '/dashboard',
    badge: { text: 'MM Only', color: '#03DAC6', bg: 'rgba(3,218,198,0.12)' },
    description: 'Market Maker hub',
  },
  { icon: User,    label: 'Profile',   to: '/profile',  description: 'Your public profile' },
  { icon: Receipt, label: 'My Bets',   to: '/mybets',   description: 'Active & past bets' },
  { icon: Wallet,  label: 'Wallet',    to: '/wallet',   description: 'Tokens & transactions' },
  { icon: Trophy,  label: 'Arena',     description: 'Leaderboards & events' },
  { icon: Flame,   label: 'Hot Topic', to: '/explore',  description: 'Trending this week' },
]

const UTILITY_ITEMS = [
  { icon: Settings,    label: 'Settings' },
  { icon: HelpCircle,  label: 'Help' },
]

function DrawerNavRow({ item, active = false }) {
  const [hovered, setHovered] = useState(false)
  const highlighted = hovered || active
  const Icon = item.icon

  const rowStyle = {
    display: 'flex', alignItems: 'center', gap: 12,
    width: '100%', textAlign: 'left', textDecoration: 'none',
    background: highlighted ? 'rgba(108,99,255,0.10)' : 'none',
    border: 'none',
    borderLeft: `3px solid ${active ? '#6C63FF' : 'transparent'}`,
    borderRadius: active || hovered ? '0 8px 8px 0' : 0,
    cursor: 'pointer',
    padding: '11px 14px',
    transition: 'background 0.15s, border-color 0.15s',
  }

  const handlers = {
    onMouseEnter: () => setHovered(true),
    onMouseLeave: () => setHovered(false),
  }

  const inner = (
    <>
      {/* Icon */}
      <div style={{
        width: 34, height: 34, borderRadius: 8, flexShrink: 0,
        backgroundColor: highlighted ? 'rgba(108,99,255,0.18)' : 'rgba(42,42,62,0.8)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        transition: 'background 0.15s',
      }}>
        <Icon size={17} color={highlighted ? '#9B8FFF' : '#8B8FA8'} />
      </div>

      {/* Label + description */}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <span style={{
            fontSize: 14, fontWeight: highlighted ? 600 : 500,
            color: highlighted ? 'white' : '#C8CAD8',
            transition: 'color 0.15s',
          }}>
            {item.label}
          </span>
          {item.badge && (
            <span style={{
              fontSize: 9, fontWeight: 700, letterSpacing: '0.06em',
              color: item.badge.color, backgroundColor: item.badge.bg,
              border: `1px solid ${item.badge.color}`,
              borderRadius: 999, padding: '1px 6px',
              textTransform: 'uppercase', flexShrink: 0,
              display: 'flex', alignItems: 'center', gap: 3,
            }}>
              <Crown size={8} />
              {item.badge.text}
            </span>
          )}
        </div>
        {item.description && (
          <div style={{ fontSize: 11, color: '#8B8FA8', marginTop: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
            {item.description}
          </div>
        )}
      </div>
    </>
  )

  // Internal React route — use Link to avoid full page reload
  if (item.to) {
    return <Link to={item.to} style={rowStyle} {...handlers}>{inner}</Link>
  }
  // href is intentionally leaving the React app (e.g. /login, /signup → Flutter routes)
  if (item.href) {
    return <a href={item.href} style={rowStyle} {...handlers}>{inner}</a>
  }
  return <button style={rowStyle} {...handlers}>{inner}</button>
}

function SideDrawer({ open, onClose }) {
  return (
    <>
      {/* Backdrop */}
      {open && (
        <div
          onClick={onClose}
          style={{
            position: 'fixed', inset: 0,
            backgroundColor: 'rgba(0,0,0,0.55)',
            zIndex: 40, backdropFilter: 'blur(3px)',
          }}
        />
      )}

      {/* Panel */}
      <div style={{
        position: 'fixed', top: 0, left: 0, bottom: 0, width: 280,
        backgroundColor: '#12122A',
        borderRight: '1px solid #2A2A3E',
        zIndex: 50, display: 'flex', flexDirection: 'column',
        transform: open ? 'translateX(0)' : 'translateX(-100%)',
        transition: 'transform 0.28s cubic-bezier(0.4,0,0.2,1)',
        boxShadow: open ? '8px 0 32px rgba(0,0,0,0.55)' : 'none',
      }}>

        {/* ── Header ── */}
        <div style={{
          display: 'flex', alignItems: 'center', justifyContent: 'space-between',
          padding: '18px 20px 16px',
          borderBottom: '1px solid #2A2A3E',
        }}>
          <div>
            <div style={{ fontWeight: 800, fontSize: 15, color: 'white', letterSpacing: '-0.2px' }}>
              N.O.R.A. Platforms
            </div>
            <div style={{ fontSize: 11, color: '#6C63FF', marginTop: 2, fontWeight: 600 }}>Phase 1</div>
          </div>
          <button
            onClick={onClose}
            style={{
              background: 'rgba(42,42,62,0.8)', border: 'none', cursor: 'pointer',
              color: '#8B8FA8', display: 'flex', borderRadius: 8,
              padding: 7, transition: 'background 0.15s, color 0.15s',
            }}
            onMouseEnter={e => { e.currentTarget.style.background = 'rgba(108,99,255,0.2)'; e.currentTarget.style.color = 'white' }}
            onMouseLeave={e => { e.currentTarget.style.background = 'rgba(42,42,62,0.8)'; e.currentTarget.style.color = '#8B8FA8' }}
          >
            <X size={17} />
          </button>
        </div>

        {/* ── Guest user area ── */}
        <div style={{
          margin: '14px 16px',
          backgroundColor: 'rgba(108,99,255,0.08)',
          border: '1px solid rgba(108,99,255,0.2)',
          borderRadius: 12, padding: '12px 14px',
          display: 'flex', alignItems: 'center', gap: 12,
        }}>
          {/* Avatar placeholder */}
          <div style={{
            width: 40, height: 40, borderRadius: '50%', flexShrink: 0,
            background: 'linear-gradient(135deg, #2A2A3E, #3A3A5E)',
            border: '2px solid #2A2A3E',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <User size={18} color="#8B8FA8" />
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 13, fontWeight: 600, color: '#C8CAD8' }}>Guest</div>
            <div style={{ fontSize: 11, color: '#8B8FA8', marginTop: 1 }}>Sign in for full access</div>
          </div>
          <a href="/login" style={{
            display: 'flex', alignItems: 'center', gap: 5,
            background: 'none', border: '1px solid #6C63FF', borderRadius: 7,
            color: '#9B8FFF', fontSize: 12, fontWeight: 600, cursor: 'pointer',
            padding: '6px 10px', flexShrink: 0, transition: 'background 0.15s',
            textDecoration: 'none',
          }}
            onMouseEnter={e => { e.currentTarget.style.background = 'rgba(108,99,255,0.2)' }}
            onMouseLeave={e => { e.currentTarget.style.background = 'none' }}
          >
            <LogIn size={13} />
            Sign in
          </a>
        </div>

        {/* ── Main navigation ── */}
        <div style={{ padding: '6px 0', flex: 1, overflowY: 'auto' }}>
          <div style={{ padding: '4px 20px 8px', fontSize: 10, fontWeight: 700, color: '#8B8FA8', letterSpacing: '0.1em', textTransform: 'uppercase' }}>
            Navigate
          </div>
          {NAV_ITEMS.map(item => (
            <DrawerNavRow key={item.label} item={item} />
          ))}
        </div>

        {/* ── Divider ── */}
        <div style={{ height: 1, backgroundColor: '#2A2A3E', margin: '0 16px' }} />

        {/* ── Utility items ── */}
        <div style={{ padding: '8px 0 16px' }}>
          <div style={{ padding: '8px 20px 6px', fontSize: 10, fontWeight: 700, color: '#8B8FA8', letterSpacing: '0.1em', textTransform: 'uppercase' }}>
            Support
          </div>
          {UTILITY_ITEMS.map(item => (
            <DrawerNavRow key={item.label} item={item} />
          ))}
        </div>

        {/* ── Footer version tag ── */}
        <div style={{
          padding: '10px 20px 14px',
          borderTop: '1px solid #2A2A3E',
          fontSize: 11, color: '#8B8FA8',
          display: 'flex', justifyContent: 'space-between',
        }}>
          <span>v1.0.0 — Phase 1</span>
          <span style={{ color: '#2A2A3E' }}>NORA</span>
        </div>

      </div>
    </>
  )
}

// ─── Tier badge ───────────────────────────────────────────────────────────────

function TierBadge({ tier }) {
  const info = {
    on_fire: { emoji: '🔥', label: 'On Fire', color: '#FF6B35' },
    rising:  { emoji: '⚡', label: 'Rising',  color: '#FFD700' },
    watched: { emoji: '👀', label: 'Watched', color: '#6C63FF' },
  }[tier]
  if (!info) return null
  return (
    <span style={{
      fontSize: 9, fontWeight: 700, color: info.color,
      backgroundColor: `${info.color}1F`,
      border: `1px solid ${info.color}59`,
      borderRadius: 999, padding: '2px 6px',
    }}>
      {info.emoji} {info.label}
    </span>
  )
}

// ─── Rising carousel ──────────────────────────────────────────────────────────

const AVATAR_PALETTE = ['#6C63FF','#00C896','#FF6B35','#EE1D52','#9146FF','#FFD700','#00BCD4']
function avatarColor(label) {
  const code = [...label].reduce((s, c) => s + c.charCodeAt(0), 0)
  return AVATAR_PALETTE[code % AVATAR_PALETTE.length]
}

function RisingSection() {
  const { creators, liveIds, loading } = useRisingCreators()

  return (
    <section style={{ padding: '0 24px 36px' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, marginBottom: 14 }}>
        <Zap size={16} color="#FFD700" style={{ marginBottom: -2, flexShrink: 0 }} />
        <span style={{ fontSize: 17, fontWeight: 700, color: 'white' }}>Rising</span>
        <span style={{ fontSize: 12, color: '#8B8FA8' }}>Market Makers gaining traction</span>
      </div>

      {loading ? (
        <div style={{ display: 'flex', gap: 12, overflowX: 'auto' }}>
          {[...Array(6)].map((_, i) => (
            <div key={i} style={{ width: 110, height: 120, borderRadius: 14, backgroundColor: '#1A1A2E', flexShrink: 0, opacity: 0.5 }} />
          ))}
        </div>
      ) : creators.length === 0 ? (
        <p style={{ color: '#8B8FA8', fontSize: 14, margin: 0 }}>No rising creators yet</p>
      ) : (
        <div style={{ display: 'flex', gap: 12, overflowX: 'auto', paddingBottom: 4 }}>
          {creators.map(c => {
            const isLive = liveIds.has(c.id)
            const color = avatarColor(c.label)
            return (
              <div key={c.id} style={{
                width: 110, flexShrink: 0,
                backgroundColor: '#1A1A2E',
                border: `1px solid ${isLive ? '#FF475780' : '#2A2A3E'}`,
                borderRadius: 14, padding: 12,
                display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6,
              }}>
                {/* Avatar + live dot */}
                <div style={{ position: 'relative' }}>
                  <div style={{
                    width: 44, height: 44, borderRadius: '50%',
                    backgroundColor: `${color}26`,
                    border: `1.5px solid ${color}66`,
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    fontSize: 18, fontWeight: 700, color,
                  }}>
                    {c.label[0].toUpperCase()}
                  </div>
                  {isLive && (
                    <div style={{
                      position: 'absolute', top: -2, right: -2,
                      width: 10, height: 10, borderRadius: '50%',
                      backgroundColor: '#FF4757',
                      border: '1.5px solid #0A0A0F',
                    }} />
                  )}
                </div>

                <div style={{ fontSize: 12, fontWeight: 600, color: 'white', textAlign: 'center', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', width: '100%' }}>
                  {c.label}
                </div>

                {c.tier && <TierBadge tier={c.tier} />}

                {c.heatScore > 0 && (
                  <div style={{ fontSize: 10, color: '#8B8FA8' }}>
                    🔥 {c.heatScore.toFixed(1)}
                  </div>
                )}
              </div>
            )
          })}
        </div>
      )}
    </section>
  )
}

// ─── Who's Live ───────────────────────────────────────────────────────────────

function formatViewers(n) {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`
  return String(n)
}

function WhoIsLiveSection() {
  const { metrics, loading } = useLiveFeed()

  return (
    <section style={{ padding: '0 24px 36px' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, marginBottom: 14 }}>
        <Radio size={16} color='#FF4757' style={{ marginBottom: -2, flexShrink: 0 }} />
        <span style={{ fontSize: 17, fontWeight: 700, color: 'white' }}>Who's Live</span>
        <span style={{ fontSize: 12, color: '#8B8FA8' }}>Creators streaming right now</span>
      </div>

      {loading ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          {[...Array(3)].map((_, i) => (
            <div key={i} style={{ height: 100, borderRadius: 16, backgroundColor: '#1A1A2E', opacity: 0.5 }} />
          ))}
        </div>
      ) : metrics.length === 0 ? (
        <div style={{
          display: 'flex', flexDirection: 'column', alignItems: 'center',
          padding: '32px 0', gap: 10, color: '#8B8FA8',
        }}>
          <Radio size={36} color='#8B8FA8' />
          <span style={{ fontSize: 14 }}>No creators are live right now</span>
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          {metrics.map((m, i) => {
            const isYT = m.platform === 'youtube'
            const platformLabel = isYT ? 'YT' : 'Twitch'
            const platformColor = isYT ? '#FF4444' : '#9146FF'
            return (
              <div key={i} style={{
                backgroundColor: '#1A1A2E',
                border: '1px solid #2A2A3E',
                borderRadius: 16, padding: 16,
              }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: m.streamTitle ? 8 : 12 }}>
                  {/* Platform chip */}
                  <span style={{
                    fontSize: 11, fontWeight: 600, color: platformColor,
                    backgroundColor: `${platformColor}1F`,
                    border: `1px solid ${platformColor}59`,
                    borderRadius: 6, padding: '3px 7px', flexShrink: 0,
                  }}>
                    {platformLabel}
                  </span>

                  <span style={{ flex: 1, fontSize: 15, fontWeight: 700, color: 'white', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {m.username ? `@${m.username}` : 'Unknown'}
                  </span>

                  {/* Heat score */}
                  <span style={{
                    display: 'flex', alignItems: 'center', gap: 4,
                    fontSize: 12, fontWeight: 700, color: '#6C63FF',
                    backgroundColor: '#6C63FF1F',
                    border: '1px solid #6C63FF66',
                    borderRadius: 12, padding: '4px 9px', flexShrink: 0,
                  }}>
                    🔥 {m.heatScore.toFixed(1)}
                  </span>
                </div>

                {m.streamTitle && (
                  <p style={{ margin: '0 0 4px', fontSize: 14, color: 'white', overflow: 'hidden', display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical' }}>
                    {m.streamTitle}
                  </p>
                )}
                {m.streamCategory && (
                  <p style={{ margin: '0 0 10px', fontSize: 12, color: '#8B8FA8' }}>{m.streamCategory}</p>
                )}

                <div style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
                  <Eye size={13} color='#FF4757' />
                  <span style={{ fontSize: 13, fontWeight: 600, color: '#FF4757' }}>{formatViewers(m.viewers)}</span>
                  <span style={{ fontSize: 12, color: '#8B8FA8' }}>watching</span>
                </div>
              </div>
            )
          })}
        </div>
      )}
    </section>
  )
}

// ─── Footer ───────────────────────────────────────────────────────────────────

function FooterLinks() {
  const linkStyle = {
    color: '#8B8FA8', fontSize: 12,
    textDecoration: 'underline',
    textDecorationColor: '#8B8FA8',
  }
  return (
    <footer style={{
      display: 'flex', justifyContent: 'center', alignItems: 'center', gap: 6,
      padding: '0 24px 32px',
    }}>
      <a href="/privacy" style={linkStyle}>Privacy Policy</a>
      <span style={{ color: '#8B8FA8', fontSize: 12 }}>·</span>
      <a href="/terms" style={linkStyle}>Terms of Service</a>
    </footer>
  )
}

// ─── Main Landing component ───────────────────────────────────────────────────

export default function Landing() {
  const [activeTab, setActiveTab] = useState(0)
  const [slide, setSlide] = useState(0)
  const [drawerOpen, setDrawerOpen] = useState(false)
  const timerRef = useRef(null)

  const resetTimer = useCallback(() => {
    clearInterval(timerRef.current)
    timerRef.current = setInterval(() => {
      setSlide(p => (p + 1) % CREATORS.length)
    }, 5000)
  }, [])

  useEffect(() => {
    resetTimer()
    return () => clearInterval(timerRef.current)
  }, [resetTimer])

  const goTo = useCallback((i) => {
    setSlide(i)
    resetTimer()
  }, [resetTimer])

  const prev = useCallback(() => goTo((slide - 1 + CREATORS.length) % CREATORS.length), [slide, goTo])
  const next = useCallback(() => goTo((slide + 1) % CREATORS.length), [slide, goTo])

  const creator = CREATORS[slide]

  return (
    <>
      {/* Global keyframes */}
      <style>{`
        @keyframes fadeIn {
          from { opacity: 0; }
          to   { opacity: 1; }
        }
        @keyframes slideUp {
          from { opacity: 0; transform: translateY(10px); }
          to   { opacity: 1; transform: translateY(0); }
        }
      `}</style>

      <div style={{ minHeight: '100vh', backgroundColor: '#0A0A0F', color: 'white' }}>

        <SideDrawer open={drawerOpen} onClose={() => setDrawerOpen(false)} />

        {/* ── HEADER ─────────────────────────────────────────────────────── */}
        <header style={{
          borderBottom: '1px solid #2A2A3E',
          padding: '12px 24px',
          display: 'flex', alignItems: 'center', gap: 12,
          position: 'sticky', top: 0, zIndex: 30,
          backgroundColor: 'rgba(10,10,15,0.92)',
          backdropFilter: 'blur(12px)',
        }}>
          {/* Hamburger */}
          <button
            onClick={() => setDrawerOpen(true)}
            style={{ background: 'none', border: 'none', cursor: 'pointer', padding: 6, display: 'flex', alignItems: 'center', borderRadius: 6 }}
          >
            <Menu size={21} color="white" />
          </button>

          {/* Logo */}
          <div style={{ border: '1px solid #2A2A3E', borderRadius: 8, padding: '6px 12px', flexShrink: 0, lineHeight: 1 }}>
            <div style={{ fontWeight: 800, fontSize: 13, color: 'white', letterSpacing: '-0.2px' }}>N.O.R.A. Platforms</div>
            <div style={{ fontSize: 11, color: '#8B8FA8', marginTop: 3 }}>Phase 1</div>
          </div>

          {/* Learn more pill */}
          <button style={{
            border: '1px solid #2A2A3E', borderRadius: 999,
            backgroundColor: 'transparent', padding: '7px 16px',
            fontSize: 12, color: '#8B8FA8', cursor: 'pointer', flexShrink: 0,
            transition: 'border-color 0.15s, color 0.15s',
          }}
            onMouseEnter={e => { e.currentTarget.style.borderColor = '#6C63FF'; e.currentTarget.style.color = 'white' }}
            onMouseLeave={e => { e.currentTarget.style.borderColor = '#2A2A3E'; e.currentTarget.style.color = '#8B8FA8' }}
          >
            Learn more about Phase 2 and Phase 3
          </button>

          {/* Search */}
          <div style={{ position: 'relative', flex: 1, maxWidth: 420 }}>
            <Search
              size={15} color="#8B8FA8"
              style={{ position: 'absolute', left: 13, top: '50%', transform: 'translateY(-50%)', pointerEvents: 'none' }}
            />
            <input
              placeholder="Search"
              style={{
                width: '100%', backgroundColor: '#1A1A2E',
                border: '1px solid #2A2A3E', borderRadius: 999,
                color: 'white', paddingLeft: 38, paddingRight: 16,
                paddingTop: 9, paddingBottom: 9, fontSize: 13,
                outline: 'none', boxSizing: 'border-box',
                transition: 'border-color 0.15s',
              }}
              onFocus={e => { e.target.style.borderColor = '#6C63FF' }}
              onBlur={e => { e.target.style.borderColor = '#2A2A3E' }}
            />
          </div>

          {/* Spacer */}
          <div style={{ flex: 1 }} />

          {/* Auth */}
          <a href="/login" style={{ background: 'none', border: 'none', color: '#8B8FA8', fontSize: 14, fontWeight: 500, cursor: 'pointer', padding: '8px 4px', transition: 'color 0.15s', textDecoration: 'none' }}
            onMouseEnter={e => { e.currentTarget.style.color = 'white' }}
            onMouseLeave={e => { e.currentTarget.style.color = '#8B8FA8' }}
          >
            Login
          </a>
          <a href="/signup" style={{
            backgroundColor: '#6C63FF', border: 'none', borderRadius: 8,
            color: 'white', fontSize: 14, fontWeight: 600,
            padding: '8px 18px', cursor: 'pointer',
            transition: 'background-color 0.15s, box-shadow 0.15s',
            textDecoration: 'none',
          }}
            onMouseEnter={e => { e.currentTarget.style.backgroundColor = '#7B73FF'; e.currentTarget.style.boxShadow = '0 0 16px rgba(108,99,255,0.45)' }}
            onMouseLeave={e => { e.currentTarget.style.backgroundColor = '#6C63FF'; e.currentTarget.style.boxShadow = 'none' }}
          >
            Sign Up
          </a>
        </header>

        {/* ── CATEGORY NAV ────────────────────────────────────────────────── */}
        <nav style={{ borderBottom: '1px solid #2A2A3E', padding: '0 24px', display: 'flex', gap: 4, overflowX: 'auto' }}>
          {TABS.map((tab, i) => {
            const isActive = activeTab === i
            const sharedStyle = {
              padding: '13px 14px',
              fontSize: 13, fontWeight: isActive ? 600 : 400,
              color: isActive ? 'white' : '#8B8FA8',
              borderBottom: `2px solid ${isActive ? '#6C63FF' : 'transparent'}`,
              transition: 'color 0.15s, border-color 0.15s',
              whiteSpace: 'nowrap', flexShrink: 0, cursor: 'pointer',
            }

            if (tab.href) {
              return (
                <a
                  key={tab.label}
                  href={tab.href}
                  style={{ ...sharedStyle, background: 'none', border: 'none', textDecoration: 'none', display: 'inline-flex', alignItems: 'center', fontWeight: 600, color: '#6C63FF' }}
                  onMouseEnter={e => { e.currentTarget.style.color = '#9B8FFF' }}
                  onMouseLeave={e => { e.currentTarget.style.color = '#6C63FF' }}
                >
                  {tab.label} →
                </a>
              )
            }

            return (
              <button
                key={tab.label}
                onClick={() => setActiveTab(i)}
                style={{ ...sharedStyle, background: 'none', border: 'none' }}
                onMouseEnter={e => { if (!isActive) e.currentTarget.style.color = 'white' }}
                onMouseLeave={e => { if (!isActive) e.currentTarget.style.color = '#8B8FA8' }}
              >
                {tab.label}
              </button>
            )
          })}
        </nav>

        {/* ── MAIN CONTENT ─────────────────────────────────────────────────── */}
        <main style={{ padding: '24px 24px 40px' }}>

          {/* Section heading */}
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 12, marginBottom: 18 }}>
            <span style={{ fontSize: 27, fontWeight: 800, color: '#6C63FF', letterSpacing: '-0.5px' }}>
              {ORDINALS[slide]}
            </span>
            <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.3px' }}>
              Weekly Spotlight
            </h1>
          </div>

          {/* Three-column layout */}
          <div style={{ display: 'flex', gap: 16, alignItems: 'stretch' }}>

            {/* ── SPOTLIGHT CARD ── */}
            <SpotlightCard
              creator={creator}
              onPrev={prev}
              onNext={next}
              currentSlide={slide}
              onDotClick={goTo}
            />

            {/* ── RANK SIDEBAR ── */}
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10, width: 224, flexShrink: 0 }}>
              {CREATORS.slice(1).map(c => (
                <RankCard
                  key={c.rank}
                  creator={c}
                  isActive={slide === c.rank - 1}
                  onClick={() => goTo(c.rank - 1)}
                />
              ))}
            </div>

            {/* ── RIGHT COLUMN ── */}
            <div style={{ display: 'flex', flexDirection: 'column', gap: 14, width: 244, flexShrink: 0 }}>
              <NewsPanel />
              <GetTokensButton />
            </div>

          </div>
        </main>

        {/* ── DIVIDER ────────────────────────────────────────────────────── */}
        <div style={{ height: 1, backgroundColor: '#2A2A3E', margin: '0 24px 36px' }} />

        {/* ── RISING CREATORS ────────────────────────────────────────────── */}
        <RisingSection />

        {/* ── WHO'S LIVE ──────────────────────────────────────────────────── */}
        <WhoIsLiveSection />

        {/* ── FOOTER ──────────────────────────────────────────────────────── */}
        <FooterLinks />

      </div>
    </>
  )
}
